import Darwin
import Foundation

/// FTP client engine for the Files tab (RFC 959 / 2428 / 3659), plain FTP only
/// — explicit FTPS (AUTH TLS) is NOT implemented. macOS has no usable system
/// FTP client (URLSession's FTP support is gone), so this is a small hand-rolled
/// one in the same blocking-BSD-socket style as `FTPServer`.
///
/// - One control connection on a private serial queue; every public call is
///   async and runs strictly after the previous one.
/// - Passive only: EPSV first (works over IPv6 and through NAT), PASV when the
///   server does not know it. The data connection ALWAYS goes to the control
///   connection's own address — never the one in a 227 reply: a server behind
///   NAT advertises an unroutable private IP, and a hostile one could aim us at
///   a third host (curl's `--ftp-skip-pasv-ip` default).
/// - MLSD when FEAT lists MLST, LIST otherwise (Unix and Windows/DOS listings).
/// - Downloads land in a hidden temp file next to the destination and are
///   renamed into place only after a whole, confirmed (226 + SIZE) transfer;
///   cancel/failure leaves nothing at the destination.
/// - Cancelling the Task closes the data socket at once, sends ABOR and reads
///   the control connection back into step (`PWD` is the sentinel: everything
///   before its 257 is discarded). If that fails the connection is closed.
/// - Nothing is ever logged and no password is put in an error message.
nonisolated final class FTPClient: RemoteFileClient, @unchecked Sendable {
    var canBrowse: Bool { true }

    static let connectTimeout: TimeInterval = 15
    /// No reply / no data for this long = a dead peer.
    static let stallTimeout: TimeInterval = 60
    private static let chunk = 128 * 1024
    private static let maximumListing = 16 * 1024 * 1024

    private let queue = DispatchQueue(label: "sheepterm.ftp.client")
    private let lock = NSLock()
    // Lock-protected.
    private var closed = false
    // Queue-confined (touched only inside `run` bodies and the close block).
    private var control: Int32 = -1
    private var dead = false
    private var buffer: [UInt8] = []
    private var peer = sockaddr_storage()
    private var peerLength: socklen_t = 0
    private var peerFamily: Int32 = AF_INET
    private var epsvBroken = false
    private var hasMLST = false
    private var hasSIZE = true
    private var homePath = "/"

    private init() {}

    // MARK: Per-call cancellation

    private final class Op: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        private var fd: Int32 = -1
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() {
            lock.lock()
            flag = true
            if fd >= 0, shutdownOnCancel { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
        }
        private var shutdownOnCancel = true
        /// An upload keeps its socket open on cancel: the writer notices within a
        /// poll slice and closes it with a RST (`reset`), which a shutdown's FIN
        /// would pre-empt.
        func attach(_ descriptor: Int32, shutdownOnCancel: Bool = true) {
            lock.lock(); fd = descriptor; self.shutdownOnCancel = shutdownOnCancel; lock.unlock()
        }
        /// Detaches under the lock, then closes — a late cancel() can then never
        /// shut down a descriptor number the system has already reused.
        func release(_ descriptor: Int32) {
            lock.lock()
            let owned = fd == descriptor
            fd = -1
            lock.unlock()
            if owned { Darwin.close(descriptor) }
        }
        /// Closes the attached data socket with a RST (linger 0): a server
        /// reading an upload then sees an error, not a clean end of file, and
        /// discards what it has instead of keeping a truncated file.
        func reset() {
            lock.lock()
            if fd >= 0 {
                var l = linger(l_onoff: 1, l_linger: 0)
                setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
                Darwin.close(fd)
                fd = -1
            }
            lock.unlock()
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (FTPClient, Op) throws -> T) async throws -> T {
        let op = Op()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    do {
                        if op.cancelled { throw RemoteFileError.cancelled }
                        if self.isClosed { throw RemoteFileError.connection("Connection closed") }
                        if self.dead { throw RemoteFileError.connection("Connection lost") }
                        continuation.resume(returning: try body(self, op))
                    } catch let error as RemoteFileError {
                        continuation.resume(throwing: error)
                    } catch {
                        continuation.resume(throwing: RemoteFileError.connection(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            op.cancel()
        }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    // MARK: Connect

    static func connect(_ endpoint: RemoteEndpoint) async throws -> FTPClient {
        let client = FTPClient()
        do {
            try await client.run { c, op in try c.doConnect(endpoint, op) }
        } catch {
            client.close()
            throw error
        }
        return client
    }

    private func doConnect(_ endpoint: RemoteEndpoint, _ op: Op) throws {
        guard let port = UInt16(exactly: endpoint.port), port > 0 else {
            throw RemoteFileError.connection("Bad port \(endpoint.port)")
        }
        try openControl(host: endpoint.host, port: port, op)
        do {
            var greeting = try readReply(op, timeout: Self.connectTimeout)
            if greeting.code == 120 { greeting = try readReply(op, timeout: Self.connectTimeout) }
            guard greeting.code == 220 else { throw RemoteFileError.connection("FTP \(greeting.summary)") }
            let anonymous = endpoint.username.isEmpty
            let name = anonymous ? "anonymous" : endpoint.username
            var reply = try command(op, "USER \(try clean(name))")
            if reply.code == 331 || reply.code == 332 {
                if anonymous, endpoint.password == nil {
                    reply = try command(op, "PASS anonymous@")
                } else {
                    guard let password = endpoint.password else { throw RemoteFileError.passwordRequired }
                    reply = try command(op, "PASS \(try clean(password))", secret: true)
                }
            }
            switch reply.code {
            case 230, 202: break
            case 530, 430, 331, 332, 532: throw RemoteFileError.authenticationFailed
            default: throw RemoteFileError.connection("FTP \(reply.summary)")
            }
            _ = try? command(op, "TYPE I")
            if let features = try? command(op, "FEAT"), features.code == 211 {
                let lines = features.text.uppercased()
                hasMLST = lines.contains("MLST")
                if lines.contains("UTF8") { _ = try? command(op, "OPTS UTF8 ON") }
                if hasMLST { _ = try? command(op, "OPTS MLST type;size;modify;perm;unix.mode;") }
            }
            if let pwd = try? command(op, "PWD"), pwd.code == 257 { homePath = Self.parsePWD(pwd.text) ?? "/" }
        } catch {
            drop()
            throw error
        }
    }

    private func openControl(host: String, port: UInt16, _ op: Op) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw RemoteFileError.connection("Cannot find \(host)")
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        while let info = cursor {
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            if let fd = FTPSocket.connect(address: info.pointee.ai_addr, length: info.pointee.ai_addrlen,
                                          family: info.pointee.ai_family, timeoutMs: left,
                                          abort: { op.cancelled || self.isClosed }) {
                control = fd
                memcpy(&peer, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
                peerLength = info.pointee.ai_addrlen
                peerFamily = info.pointee.ai_family
                return
            }
            if op.cancelled { throw RemoteFileError.cancelled }
            cursor = info.pointee.ai_next
        }
        throw RemoteFileError.connection("Cannot connect to \(host):\(port)")
    }

    // MARK: Control channel

    private struct Reply {
        let code: Int
        let text: String
        /// First line without its code — what an error shows.
        var summary: String {
            let line = text.split(separator: "\n").first.map(String.init) ?? text
            return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Paths and names go on a command line: a CR/LF would smuggle a second
    /// command.
    private func clean(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw RemoteFileError.remote("Invalid name")
        }
        return text
    }

    @discardableResult
    private func command(_ op: Op, _ line: String, secret: Bool = false) throws -> Reply {
        let bytes = Array((line + "\r\n").utf8)
        guard FTPSocket.writeAll(control, bytes, timeoutMs: 10_000, abort: { op.cancelled || self.isClosed }) else {
            if op.cancelled { markDead(); throw RemoteFileError.cancelled }
            markDead()
            throw RemoteFileError.connection("Connection lost")
        }
        return try readReply(op)
    }

    /// One full reply, multi-line aware ("123-…" … "123 …").
    /// A control reply larger than this (a line with no LF, or a multi-line
    /// reply that never ends) is a broken or hostile server.
    static let maximumReplyBytes = 64 * 1024

    private func readReply(_ op: Op, timeout: TimeInterval = FTPClient.stallTimeout, cancellable: Bool = true) throws -> Reply {
        var collected: [String] = []
        var collectedBytes = 0
        var multiline: String?
        while true {
            guard buffer.count <= Self.maximumReplyBytes, collectedBytes <= Self.maximumReplyBytes else {
                markDead()
                throw RemoteFileError.connection("The server sent an oversized reply")
            }
            if let line = takeLine() {
                collectedBytes += line.utf8.count
                let bytes = Array(line.utf8)
                let hasCode = bytes.count >= 3 && bytes[0...2].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                if let code = multiline {
                    collected.append(line)
                    if line.hasPrefix(code + " ") || line == code { return Reply(code: Int(code)!, text: collected.joined(separator: "\n")) }
                    continue
                }
                guard hasCode else { continue }
                let code = String(line.prefix(3))
                if bytes.count == 3 || bytes[3] == 0x20 {
                    return Reply(code: Int(code)!, text: line)
                }
                if bytes[3] == 0x2D { multiline = code; collected = [line] }
                continue
            }
            try fill(op, timeout: timeout, cancellable: cancellable)
        }
    }

    private func takeLine() -> String? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var bytes = Array(buffer[..<newline])
        buffer.removeSubrange(...newline)
        while bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func fill(_ op: Op, timeout: TimeInterval, cancellable: Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if cancellable, op.cancelled { markDead(); throw RemoteFileError.cancelled }
            if isClosed { throw RemoteFileError.connection("Connection closed") }
            guard Date() < deadline else { markDead(); throw RemoteFileError.connection("The server stopped answering") }
            let ready = FTPSocket.poll(control, events: Int16(POLLIN), timeoutMs: 250)
            if ready < 0 { markDead(); throw RemoteFileError.connection("Connection lost") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = recv(control, &bytes, bytes.count, 0)
            if count == 0 { markDead(); throw RemoteFileError.connection("The server closed the connection") }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                markDead(); throw RemoteFileError.connection("Connection lost")
            }
            buffer.append(contentsOf: bytes[..<count])
            return
        }
    }

    private func markDead() { dead = true }

    private func drop() {
        dead = true
        if control >= 0 { Darwin.close(control); control = -1 }
    }

    /// A failed command → the matching error.
    private func failure(_ reply: Reply, path: String) -> RemoteFileError {
        let lower = reply.text.lowercased()
        switch reply.code {
        case 530, 430: return .authenticationFailed
        case 550, 553, 450, 451, 452, 532:
            if lower.contains("exist") && !lower.contains("not exist") && !lower.contains("no such")
                && !lower.contains("doesn't exist") { return .alreadyExists(path) }
            if lower.contains("denied") || lower.contains("permit") || lower.contains("not allowed")
                || lower.contains("disabled") || lower.contains("refused") { return .permissionDenied(path) }
            if reply.code == 450 || reply.code == 451 || reply.code == 452 { return .remote("FTP \(reply.summary)") }
            return .notFound(path)
        case 421: return .connection("FTP \(reply.summary)")
        case 500, 502, 504: return .unsupported("FTP \(reply.summary)")
        default: return .remote("FTP \(reply.code) \(reply.summary)")
        }
    }

    // MARK: Data channel

    private func openData(_ op: Op) throws -> Int32 {
        if !epsvBroken {
            let reply = try command(op, "EPSV")
            if reply.code == 229, let port = Self.parseEPSV(reply.text) {
                return try connectData(port, op)
            }
            epsvBroken = true
        }
        guard peerFamily == AF_INET else { throw RemoteFileError.unsupported("The server does not support EPSV") }
        let reply = try command(op, "PASV")
        guard reply.code == 227, let advertised = Self.parsePASV(reply.text) else {
            throw RemoteFileError.remote("FTP \(reply.code) \(reply.summary)")
        }
        // advertised.host is deliberately ignored — see the class comment.
        return try connectData(advertised.port, op)
    }

    private func connectData(_ port: UInt16, _ op: Op) throws -> Int32 {
        var address = peer
        switch peerFamily {
        case AF_INET:
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = port.bigEndian }
            }
        default:
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port = port.bigEndian }
            }
        }
        let fd = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                FTPSocket.connect(address: $0, length: peerLength, family: peerFamily, timeoutMs: 15_000,
                                  abort: { op.cancelled || self.isClosed })
            }
        }
        guard let fd else {
            if op.cancelled { throw RemoteFileError.cancelled }
            throw RemoteFileError.connection("Cannot open a data connection")
        }
        return fd
    }

    /// After a transfer stopped half-way: close, ABOR, and read the control
    /// connection back to a known place (everything up to the 257 of a PWD).
    /// The connection is dropped when that does not work.
    private func abortTransfer(_ op: Op) {
        op.reset()
        guard !dead else { return }
        let bytes = Array("ABOR\r\nPWD\r\n".utf8)
        guard FTPSocket.writeAll(control, bytes, timeoutMs: 5000, abort: { self.isClosed }) else { drop(); return }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard let reply = try? readReply(op, timeout: 8, cancellable: false) else { drop(); return }
            if reply.code == 257 { return }
        }
        drop()
    }

    // MARK: RemoteFileClient

    func home() async throws -> String {
        try await run { c, _ in c.homePath }
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        try await run { c, op in try c.doList(path, op) }
    }

    private func doList(_ path: String, _ op: Op) throws -> [RemoteEntry] {
        let arg = try clean(path)
        let suffix = arg.isEmpty ? "" : " \(arg)"
        if hasMLST {
            let outcome = try collect("MLSD\(suffix)", path, op)
            if let text = outcome.text { return Self.parseMLSD(text) }
            // 500/501/502/504: no MLSD after all — LIST below.
        }
        let outcome = try collect("LIST\(suffix)", path, op)
        guard let text = outcome.text else { throw failure(outcome.reply, path: path) }
        return Self.parseList(text)
    }

    /// Runs a listing command and returns its text, or the refusing reply when
    /// the server answered with a 5xx "no such command" (so the caller can fall
    /// back); a 550 is thrown.
    private func collect(_ line: String, _ path: String, _ op: Op) throws -> (text: String?, reply: Reply) {
        let data = try openData(op)
        op.attach(data)
        defer { op.release(data) }
        let start = try command(op, line)
        guard (100..<200).contains(start.code) else {
            if [500, 501, 502, 504].contains(start.code), line.hasPrefix("MLSD") { return (nil, start) }
            if start.code == 500 || start.code == 502 { return (nil, start) }
            throw failure(start, path: path)
        }
        var all: [UInt8] = []
        var cleanRead = true
        read: while true {
            switch try waitData(data, op) {
            case .ready:
                var bytes = [UInt8](repeating: 0, count: Self.chunk)
                let count = recv(data, &bytes, bytes.count, 0)
                if count == 0 { break read }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    cleanRead = false; break read
                }
                all.append(contentsOf: bytes[..<count])
                if all.count > Self.maximumListing {
                    abortTransfer(op)
                    throw RemoteFileError.remote("The directory listing is too large")
                }
            case .failed:
                cleanRead = false; break read
            }
        }
        let end = try readReply(op)
        guard (200..<300).contains(end.code), cleanRead || !all.isEmpty else { throw failure(end, path: path) }
        return (String(decoding: all, as: UTF8.self), end)
    }

    private enum Wait { case ready, failed }

    /// Waits for data (or EOF) on `fd`: cancel → ABOR + `.cancelled`, a stall →
    /// ABOR + connection error.
    private func waitData(_ fd: Int32, _ op: Op) throws -> Wait {
        var idle = 0
        while true {
            if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
            if isClosed { throw RemoteFileError.connection("Connection closed") }
            let ready = FTPSocket.poll(fd, events: Int16(POLLIN), timeoutMs: 250)
            if ready < 0 { return .failed }
            if ready > 0 { return .ready }
            idle += 250
            if idle >= Int(Self.stallTimeout * 1000) {
                abortTransfer(op)
                throw RemoteFileError.connection("The transfer stalled")
            }
        }
    }

    func download(_ remotePath: String, to local: URL, replacing: Bool, progress: @escaping TransferProgress) async throws {
        try await run { c, op in try c.doDownload(remotePath, local, replacing, progress, op) }
    }

    private func doDownload(_ remotePath: String, _ local: URL, _ replacing: Bool, _ progress: @escaping TransferProgress, _ op: Op) throws {
        let arg = try clean(remotePath)
        var total: Int64?
        if hasSIZE {
            let size = try command(op, "SIZE \(arg)")
            if size.code == 213, let n = Int64(size.text.dropFirst(3).trimmingCharacters(in: .whitespaces)) { total = n }
            else if size.code == 500 || size.code == 502 { hasSIZE = false }
            else if size.code == 550 { throw failure(size, path: remotePath) }
        }
        // The free space less a reserve, like SFTP / SCP: a server that
        // keeps streaming (or lies in SIZE) must not fill the disk.
        let cap = DownloadCap.bytes(for: local)
        if let total, total > cap { throw RemoteFileError.remote("Not enough free space for \(remotePath)") }
        let directory = local.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(DownloadCommit.partName(for: local, tag: String(UUID().uuidString.prefix(8))))
        let file = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard file >= 0 else { throw RemoteFileError.permissionDenied(local.lastPathComponent) }
        var fileOpen = true
        var committed = false
        defer {
            if fileOpen { Darwin.close(file) }
            if !committed { unlink(temp.path) }
        }
        let data = try openData(op)
        op.attach(data)
        defer { op.release(data) }
        let start = try command(op, "RETR \(arg)")
        guard (100..<200).contains(start.code) else { throw failure(start, path: remotePath) }
        var received: Int64 = 0
        var cleanEnd = true
        var bytes = [UInt8](repeating: 0, count: Self.chunk)
        read: while true {
            switch try waitData(data, op) {
            case .ready:
                let count = recv(data, &bytes, bytes.count, 0)
                if count == 0 { break read }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
                    cleanEnd = false; break read
                }
                if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
                guard FTPSocket.writeToFile(file, Array(bytes[..<count])) else {
                    abortTransfer(op)
                    throw RemoteFileError.permissionDenied(local.lastPathComponent)
                }
                received += Int64(count)
                if received > cap {
                    abortTransfer(op)
                    throw RemoteFileError.remote("Not enough free space for \(remotePath)")
                }
                progress(received, total)
            case .failed:
                if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
                cleanEnd = false; break read
            }
        }
        if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
        let end = try readReply(op)
        guard (200..<300).contains(end.code) else { throw failure(end, path: remotePath) }
        // A reset data link with a 226 still counts when SIZE says it is whole;
        // with no SIZE a reset cannot be told from truncation.
        if let total, received != total {
            throw RemoteFileError.remote("\(remotePath) arrived incomplete: \(received) of \(total) bytes")
        }
        if total == nil, !cleanEnd { throw RemoteFileError.connection("The data connection was reset") }
        Darwin.close(file); fileOpen = false
        try DownloadCommit.commit(temp, to: local, replacing: replacing)
        committed = true
    }

    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress) async throws {
        try await run { c, op in try c.doUpload(local, remotePath, progress, op) }
    }

    private func doUpload(_ local: URL, _ remotePath: String, _ progress: @escaping TransferProgress, _ op: Op) throws {
        let arg = try clean(remotePath)
        let file = open(local.path, O_RDONLY)
        guard file >= 0 else { throw RemoteFileError.notFound(local.lastPathComponent) }
        defer { Darwin.close(file) }
        var info = stat()
        fstat(file, &info)
        let total = Int64(info.st_size)
        let data = try openData(op)
        op.attach(data, shutdownOnCancel: false)
        var dataOpen = true
        defer { if dataOpen { op.release(data) } }
        let start = try command(op, "STOR \(arg)")
        guard (100..<200).contains(start.code) else { throw failure(start, path: remotePath) }
        var sent: Int64 = 0
        var bytes = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            let count = read(file, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; abortTransfer(op); throw RemoteFileError.notFound(local.lastPathComponent) }
            if count == 0 { break }
            if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
            let ok = FTPSocket.writeAll(data, Array(bytes[..<count]), timeoutMs: Int32(Self.stallTimeout * 1000),
                                        abort: { op.cancelled || self.isClosed })
            guard ok else {
                if op.cancelled { abortTransfer(op); throw RemoteFileError.cancelled }
                abortTransfer(op)
                throw RemoteFileError.connection("The data connection was lost")
            }
            sent += Int64(count)
            progress(sent, total)
        }
        shutdown(data, SHUT_WR)
        op.release(data); dataOpen = false      // EOF to the server
        let end = try readReply(op)
        guard (200..<300).contains(end.code) else { throw failure(end, path: remotePath) }
    }

    func makeDirectory(_ path: String) async throws {
        try await run { c, op in
            let reply = try c.command(op, "MKD \(try c.clean(path))")
            guard reply.code == 257 || reply.code == 250 else { throw c.failure(reply, path: path) }
        }
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        try await run { c, op in
            let reply = try c.command(op, "\(isDirectory ? "RMD" : "DELE") \(try c.clean(path))")
            guard reply.code == 250 else { throw c.failure(reply, path: path) }
        }
    }

    func rename(_ from: String, to: String) async throws {
        try await run { c, op in
            let first = try c.command(op, "RNFR \(try c.clean(from))")
            guard first.code == 350 else { throw c.failure(first, path: from) }
            let second = try c.command(op, "RNTO \(try c.clean(to))")
            guard second.code == 250 else { throw c.failure(second, path: to) }
        }
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        guard !already else { return }
        // Behind any running call (which sees `closed` within a poll slice).
        queue.async { [self] in
            if control >= 0 {
                if !dead { _ = FTPSocket.writeAll(control, Array("QUIT\r\n".utf8), timeoutMs: 500, abort: { false }) }
                Darwin.close(control)
                control = -1
            }
            dead = true
        }
    }

    deinit {
        if control >= 0 { Darwin.close(control) }
    }

    // MARK: Parsing

    /// `257 "/path" …`, with `""` standing for a quote inside the name.
    static func parsePWD(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        var path = ""
        var index = text.index(after: open)
        while index < text.endIndex {
            if text[index] == "\"" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\"" { path.append("\""); index = text.index(after: next); continue }
                return path.isEmpty ? "/" : path
            }
            path.append(text[index])
            index = text.index(after: index)
        }
        return nil
    }

    /// `229 … (|||port|)` — the delimiter may be any character.
    static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inside = text[text.index(after: open)..<close]
        guard let delimiter = inside.first else { return nil }
        let parts = inside.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count == 5, let port = UInt16(parts[3]), port > 0 else { return nil }
        return port
    }

    /// `227 … (h1,h2,h3,h4,p1,p2)`; the parentheses are optional on the wire.
    static func parsePASV(_ text: String) -> (host: String, port: UInt16)? {
        let body: Substring
        if let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close {
            body = text[text.index(after: open)..<close]
        } else {
            body = text.dropFirst(3).drop { !$0.isNumber }
        }
        let numbers = body.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 6, numbers.prefix(6).allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return nil }
        let n = numbers.prefix(6).map { $0! }
        let port = n[4] * 256 + n[5]
        guard port > 0 else { return nil }
        return ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", UInt16(port))
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    /// The rest of `line` after `count` whitespace-separated fields, verbatim
    /// (a name's inner runs of spaces are kept).
    static func tail(of line: String, afterFields count: Int) -> String? {
        var index = line.startIndex
        for _ in 0..<count {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
        }
        guard index < line.endIndex else { return nil }
        while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
        let name = String(line[index...])
        return name.isEmpty ? nil : name
    }

    /// MLSD: `fact=value;fact=value; name`.
    static func parseMLSD(_ text: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let space = line.firstIndex(of: " ") else { continue }
            let name = String(line[line.index(after: space)...])
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                guard let equals = fact.firstIndex(of: "=") else { continue }
                facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
            }
            let type = (facts["type"] ?? "file").lowercased()
            if type == "cdir" || type == "pdir" { continue }
            var entry = RemoteEntry(name: name, isDirectory: type == "dir")
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") { entry.isSymlink = true }
            entry.size = facts["size"].flatMap { Int64($0) }
            entry.modified = facts["modify"].flatMap(parseMLSTTime)
            if let mode = facts["unix.mode"], let value = Int(mode, radix: 8) { entry.permissions = rwx(value) }
            entries.append(entry)
        }
        return sorted(entries)
    }

    private static func parseMLSTTime(_ text: String) -> Date? {
        // ASCII digits only: `isNumber` also passes "½" or "٣", which Int()
        // refuses — a server's listing must never be able to trap the app.
        let digits = Array(text.utf8.prefix(14))
        guard digits.count == 14, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        func n(_ a: Int, _ b: Int) -> Int { digits[a..<b].reduce(0) { $0 * 10 + Int($1 - 0x30) } }
        return utc(n(0, 4), n(4, 6), n(6, 8), n(8, 10), n(10, 12), n(12, 14))
    }

    private static func rwx(_ mode: Int) -> String {
        let letters = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? letters[$0] : "-" })
    }

    /// LIST: Unix `ls -l` and Windows/DOS (IIS) listings. `now` only decides
    /// the year of a Unix date shown without one.
    static func parseList(_ text: String, now: Date = Date()) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        // Split on the LF byte: "\r\n" is ONE Character in Swift and equals
        // neither "\n" nor "\r".
        let lines = text.utf8.split(separator: 0x0A).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        for line in lines where !line.isEmpty {
            if let entry = parseUnix(line, now: now) ?? parseDOS(line) {
                if entry.name == "." || entry.name == ".." { continue }
                entries.append(entry)
            }
        }
        return sorted(entries)
    }

    private static func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func parseUnix(_ line: String, now: Date) -> RemoteEntry? {
        guard let kind = line.first, "-dlcbps".contains(kind) else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 7, fields[0].count >= 10 else { return nil }
        // Find "<size> <Mon> <day> <time|year>" — owner/group may be one
        // word, two, or missing, so anchor on the month.
        var anchor: Int?
        for m in 3...min(fields.count - 3, 7) where monthNames.contains(fields[m].lowercased())
            && fields[m - 1].allSatisfy(\.isNumber) && Int(fields[m + 1]) != nil {
            anchor = m; break
        }
        guard let m = anchor, var name = tail(of: line, afterFields: m + 3) else { return nil }
        let size = Int64(fields[m - 1])
        var entry = RemoteEntry(name: name, isDirectory: kind == "d")
        if kind == "l" {
            entry.isSymlink = true
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            entry.name = name
        }
        entry.size = size
        entry.permissions = String(fields[0].dropFirst().prefix(9))
        let month = monthNames.firstIndex(of: fields[m].lowercased())! + 1
        let day = Int(fields[m + 1]) ?? 1
        let last = fields[m + 2]
        if last.contains(":") {
            let hm = last.split(separator: ":").compactMap { Int($0) }
            if hm.count >= 2 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                var year = calendar.component(.year, from: now)
                if var date = utc(year, month, day, hm[0], hm[1]) {
                    // A "future" date without a year is last year's.
                    if date > now.addingTimeInterval(86_400) { year -= 1; date = utc(year, month, day, hm[0], hm[1]) ?? date }
                    entry.modified = date
                }
            }
        } else if let year = Int(last) {
            entry.modified = utc(year, month, day)
        }
        return entry
    }

    /// `10-02-26  03:14PM       <DIR>          name` / `…  1234 name`.
    private static func parseDOS(_ line: String) -> RemoteEntry? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 4, let name = tail(of: line, afterFields: 3) else { return nil }
        let date = fields[0].split(separator: "-").compactMap { Int($0) }
        guard date.count == 3 else { return nil }
        let time = fields[1].uppercased()
        guard time.hasSuffix("AM") || time.hasSuffix("PM") || time.contains(":") else { return nil }
        let hm = time.dropLast(time.hasSuffix("M") ? 2 : 0).split(separator: ":").compactMap { Int($0) }
        guard hm.count >= 2 else { return nil }
        var hour = hm[0] % 12 + (time.hasSuffix("PM") ? 12 : 0)
        if !time.hasSuffix("M") { hour = hm[0] }
        let year = date[2] < 100 ? (date[2] >= 70 ? 1900 + date[2] : 2000 + date[2]) : date[2]
        var entry = RemoteEntry(name: name, isDirectory: fields[2].uppercased() == "<DIR>")
        if !entry.isDirectory {
            guard let size = Int64(fields[2].replacingOccurrences(of: ",", with: "")) else { return nil }
            entry.size = size
        }
        entry.modified = utc(year, date[0], date[1], hour, hm[1])
        return entry
    }
}
