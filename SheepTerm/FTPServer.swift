import Darwin
import Foundation

/// Plain FTP server (RFC 959 + 2428 EPSV/EPRT, 3659 MLSD/SIZE/MDTM) for
/// File ▸ File Server: a device runs `copy ftp://user:pw@<mac>/file …` and
/// pulls the one file the user picked, or (with writes allowed) pushes a
/// backup. Ported from SheepDrop's server; what changed is WHAT a name
/// resolves to — `FileServerAccess.readURL` / `writeURL` / `listing` instead
/// of a served folder — and that a write never replaces a file.
///
/// FTP is CLEARTEXT: the login and the files cross the wire unencrypted. This
/// is for trusted lab segments (SFTP is the encrypted way).
///
/// Built on blocking BSD sockets, one thread per control connection (capped
/// at 16, 4 per IP): the protocol is strictly request/reply and every wait is
/// a `poll` slice that also looks at the stop flag, so `stop()` cuts a
/// transfer within a quarter second. IPv4 only (the devices are).
///
/// Rules that must not be "simplified":
/// - the data connection must come from the control connection's own IP (a
///   PASV port is open to the whole segment), and PORT/EPRT may only name
///   that IP (no FTP bounce);
/// - STOR writes a temp file and promotes it with `renamex_np(RENAME_EXCL)` — it
///   fails when the name exists, so a device can never replace a file, even in a
///   race with another upload (and, unlike link(2), it works on exFAT/SMB);
/// - one upload is capped at `maximumUploadBytes` (16 GB): ALLO above it and a
///   stream that passes it are refused;
/// - anonymous is refused; ≤3 wrong logins and the connection is dropped, and
///   commands pipelined behind the third are not run.
nonisolated final class FTPServer: @unchecked Sendable {
    static let fallbackPort: UInt16 = 2121

    static let maximumSessions = 16
    static let maximumPerPeer = 4
    static let maximumLine = 4096
    static let maximumAuthFailures = 3
    /// Before USER/PASS succeed a connection gets this long, not the idle
    /// limit: 16 silent sockets must not hold every slot for 5 minutes.
    static let loginTimeout: TimeInterval = 30
    /// Failed logins from one address (across connections) before it is
    /// turned away for `lockout`.
    static let maximumFailuresPerPeer = 9
    static let lockout: TimeInterval = 60
    /// No command for this long = the control connection is dropped.
    static let idleTimeout: TimeInterval = 300
    /// How long a PASV/PORT data connection may take to appear.
    static let dataConnectTimeout: TimeInterval = 30
    /// No byte moving on a data connection for this long = dead peer.
    static let dataStallTimeout: TimeInterval = 60

    /// Largest single upload accepted. Settable before `start` (the harness lowers it).
    nonisolated(unsafe) var maximumUploadBytes: Int64 = FileServerPlan.maximumUpload

    private let access: FileServerAccess
    private let lock = NSLock()
    // Lock-protected.
    private var generation = 0
    private var listenFD: Int32 = -1
    private var sessions: [ObjectIdentifier: Session] = [:]
    /// Failed logins per peer address and when the last one was (lock).
    private var peerFailures: [String: (count: Int, last: Date)] = [:]

    /// False = this address is now locked out: the connection closes at
    /// once, and a login that lands while it is locked is refused (review
    /// 6.0 (4) — the other connections it held could keep guessing).
    @discardableResult
    fileprivate func noteLogin(from ip: String, ok: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ok {
            guard !isLockedOut(ip) else { return false }
            peerFailures[ip] = nil
            return true
        }
        let previous = peerFailures[ip]
        peerFailures[ip] = ((previous?.count ?? 0) + 1, Date())
        return !isLockedOut(ip)
    }

    /// Locked: an address with too many recent failures waits out `lockout`.
    private func isLockedOut(_ ip: String) -> Bool {
        guard let entry = peerFailures[ip] else { return false }
        if Date().timeIntervalSince(entry.last) > Self.lockout { peerFailures[ip] = nil; return false }
        return entry.count >= Self.maximumFailuresPerPeer
    }

    init(access: FileServerAccess) {
        self.access = access
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Binds and returns the actual port: the preferred one, or `fallbackPort`
    /// when that is taken / needs root (21). Port 0 = any free port.
    func start(preferredPort: UInt16 = 21) async throws -> UInt16 {
        stop()
        var lastError: Failure?
        for attempt in 0..<4 {
            do { return try begin(on: preferredPort) } catch let error as Failure {
                lastError = error
                guard preferredPort != Self.fallbackPort else { throw error }
                // A restart's previous socket may still be closing: retry the
                // standard port briefly before moving to the fallback.
                if attempt < 3, error.description.contains("in use") {
                    try? await Task.sleep(for: .milliseconds(150))
                } else { break }
            }
        }
        if preferredPort != Self.fallbackPort, let port = try? begin(on: Self.fallbackPort) { return port }
        throw lastError ?? Failure(description: "cannot listen")
    }

    func stop() {
        lock.lock()
        generation += 1
        let live = Array(sessions.values)
        sessions.removeAll()
        listenFD = -1       // the accept thread closes its own descriptor
        lock.unlock()
        for session in live { session.abort() }
    }

    /// Ends every upload in flight at once (the app's "writes off" switch);
    /// the files are discarded, the connections stay up.
    func abortWrites() {
        lock.lock()
        let live = Array(sessions.values)
        lock.unlock()
        for session in live { session.abortUpload() }
    }

    // MARK: Listening

    private func begin(on port: UInt16) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        FTPSocket.configure(fd)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Failure(description: code == EADDRINUSE ? "port \(port) in use"
                                                         : "port \(port): \(String(cString: strerror(code)))")
        }
        let actual = FTPSocket.localPort(fd) ?? port
        lock.lock()
        generation += 1
        let mine = generation
        listenFD = fd
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd: fd, generation: mine) }
        return actual
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    private func acceptLoop(fd: Int32, generation gen: Int) {
        defer { close(fd) }
        while isCurrent(gen) {
            guard FTPSocket.poll(fd, events: Int16(POLLIN), timeoutMs: 250) > 0 else { continue }
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { continue }
            FTPSocket.configure(client)
            let ip = FTPSocket.ipv4String(of: peer) ?? "?"
            lock.lock()
            let ok = generation == gen && sessions.count < Self.maximumSessions
                && sessions.values.filter({ $0.peerIP == ip }).count < Self.maximumPerPeer
                && !isLockedOut(ip)
            let session = Session(server: self, control: client, peerIP: ip)
            if ok { sessions[ObjectIdentifier(session)] = session }
            lock.unlock()
            if ok {
                Thread.detachNewThread { session.run() }
            } else {
                _ = FTPSocket.writeAll(client, Array("421 Too many connections\r\n".utf8), timeoutMs: 500, abort: { false })
                close(client)
            }
        }
    }

    private func sessionEnded(_ session: Session) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = nil
        lock.unlock()
    }

    // MARK: One control connection

    private final class Session: @unchecked Sendable {
        private weak var server: FTPServer?
        private let access: FileServerAccess
        private let control: Int32
        let peerIP: String

        private let fdLock = NSLock()
        private var aborted = false
        private var dataFD: Int32 = -1
        private var storing = false
        private var uploadAborted = false
        private var announced: Int64 = 0

        private var buffer: [UInt8] = []
        private var user: String?
        private var loggedIn = false
        private var failures = 0
        private var done = false
        private var tooLong = false
        private var ascii = false
        /// Pending data endpoint — a PASV/EPSV listener or a PORT/EPRT target.
        private var passive: Int32 = -1
        private var active: (ip: String, port: UInt16)?

        init(server: FTPServer, control: Int32, peerIP: String) {
            self.server = server
            self.access = server.access
            self.control = control
            self.peerIP = peerIP
        }

        func abort() {
            fdLock.lock()
            aborted = true
            shutdown(control, SHUT_RDWR)
            if dataFD >= 0 { shutdown(dataFD, SHUT_RDWR) }
            fdLock.unlock()
        }

        /// Cuts the upload in flight, if any (see `FTPServer.abortWrites`).
        func abortUpload() {
            fdLock.lock()
            if storing {
                uploadAborted = true
                if dataFD >= 0 { shutdown(dataFD, SHUT_RDWR) }
            }
            fdLock.unlock()
        }

        private var uploadWasAborted: Bool {
            fdLock.lock(); defer { fdLock.unlock() }
            return uploadAborted
        }

        /// On: from the moment a STOR is accepted (not only once its data
        /// connection is up — writes switched off while it waits for one
        /// must still end it). The abort flag is cleared only when a new
        /// upload starts, never when one ends.
        private func setStoring(_ on: Bool) {
            fdLock.lock(); storing = on; if on { uploadAborted = false }; fdLock.unlock()
        }

        private var isAborted: Bool {
            fdLock.lock(); defer { fdLock.unlock() }
            return aborted
        }

        private func setData(_ fd: Int32) {
            fdLock.lock(); dataFD = fd; fdLock.unlock()
        }

        // MARK: Loop

        func run() {
            reply("220 SheepTerm FTP ready")
            while !done && !isAborted {
                switch readLine(timeout: loggedIn ? FTPServer.idleTimeout : FTPServer.loginTimeout) {
                case .line(let line): handle(line)
                case .timeout: reply("421 Idle timeout"); done = true
                case .eof: done = true
                case .tooLong: done = true; tooLong = true
                }
            }
            closePassive()
            if tooLong {
                // Unread input on close() turns into a RST that can eat the
                // 500 we just sent: say goodbye, then drain briefly.
                shutdown(control, SHUT_WR)
                var sink = [UInt8](repeating: 0, count: 4096)
                let until = Date().addingTimeInterval(1)
                while Date() < until {
                    let ready = FTPSocket.poll(control, events: Int16(POLLIN), timeoutMs: 100)
                    if ready < 0 { break }
                    if ready > 0, recv(control, &sink, sink.count, 0) <= 0 { break }
                }
            }
            fdLock.lock()
            aborted = true
            fdLock.unlock()
            close(control)
            server?.sessionEnded(self)
        }

        private enum Line { case line(String), eof, timeout, tooLong }

        private func readLine(timeout: TimeInterval) -> Line {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    var bytes = Array(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    while bytes.last == 0x0D { bytes.removeLast() }
                    return .line(String(decoding: bytes, as: UTF8.self))
                }
                if buffer.count > FTPServer.maximumLine {
                    reply("500 Line too long")
                    return .tooLong
                }
                if isAborted { return .eof }
                guard Date() < deadline else { return .timeout }
                guard FTPSocket.poll(control, events: Int16(POLLIN), timeoutMs: 250) != 0 else { continue }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = recv(control, &chunk, chunk.count, 0)
                if count == 0 { return .eof }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return .eof
                }
                buffer.append(contentsOf: chunk[..<count])
            }
        }

        @discardableResult
        private func reply(_ text: String) -> Bool {
            let ok = FTPSocket.writeAll(control, Array((text + "\r\n").utf8), timeoutMs: 10_000, abort: { self.isAborted })
            if !ok { done = true }
            return ok
        }

        // MARK: Commands

        private func handle(_ line: String) {
            let space = line.firstIndex(of: " ")
            let verb = String(space.map { line[..<$0] } ?? Substring(line)).uppercased()
            let arg = space.map { String(line[line.index(after: $0)...]) } ?? ""

            switch verb {
            case "USER":
                user = arg
                loggedIn = false
                reply("331 Password required")
            case "PASS":
                login(arg)
            case "QUIT":
                reply("221 Bye"); done = true
            case "NOOP":
                reply("200 OK")
            case "FEAT":
                reply("211-Features:\r\n EPSV\r\n EPRT\r\n MDTM\r\n MLST type*;size*;modify*;\r\n SIZE\r\n UTF8\r\n211 End")
            case "AUTH", "PBSZ", "PROT":
                reply("502 TLS is not available")
            case _ where !loggedIn:
                reply("530 Please log in with USER and PASS")
            case "SYST": reply("215 UNIX Type: L8")
            case "OPTS": reply(arg.uppercased().hasPrefix("UTF8") || arg.uppercased().hasPrefix("MLST") ? "200 OK" : "501 Option not supported")
            case "TYPE": setType(arg)
            case "MODE": reply(arg.uppercased() == "S" ? "200 Stream mode" : "504 Only stream mode")
            case "STRU": reply(arg.uppercased() == "F" ? "200 File structure" : "504 Only file structure")
            case "PWD", "XPWD": reply("257 \"/\" is the current directory")
            case "CWD", "XCWD": changeDirectory(arg)
            case "CDUP", "XCUP": reply("250 Directory changed")
            case "PASV": openPassive(extended: false, arg: arg)
            case "EPSV": openPassive(extended: true, arg: arg)
            case "PORT": openActive(parsePORT(arg))
            case "EPRT": openActive(parseEPRT(arg))
            case "LIST", "NLST", "MLSD": listDirectory(verb)
            case "RETR": retrieve(arg)
            case "STOR": store(arg)
            case "SIZE": fileFacts(arg) { reply("213 \($0.size)") }
            case "MDTM": fileFacts(arg) { reply("213 \(Self.mdtm($0.modified))") }
            case "ABOR": reply("226 Abort successful")
            case "STOU", "APPE", "DELE", "RNFR", "RNTO", "MKD", "XMKD", "RMD", "XRMD", "SITE":
                reply("550 Not permitted")
            case "ALLO":
                let size = Int64(arg.split(separator: " ").first.map(String.init) ?? "") ?? 0
                if size > (server?.maximumUploadBytes ?? 0) { reply("552 Too large") }
                else { announced = size; reply("200 OK") }
            case "REST": reply("502 Resume is not supported")
            default: reply("502 Command not implemented")
            }
        }

        private func login(_ password: String) {
            guard let user else { reply("503 Login with USER first"); return }
            self.user = nil
            // Both compares always run, constant time per length. An empty
            // configured password never matches: there is no open server.
            let userOK = FTPServer.constantTimeEqual(user, access.username)
            let passOK = FTPServer.constantTimeEqual(password, access.password)
            let named = user.lowercased()
            if userOK && passOK && !access.password.isEmpty && named != "anonymous" && named != "ftp" {
                guard server?.noteLogin(from: peerIP, ok: true) != false else {
                    reply("421 Too many failed logins"); done = true; return
                }
                loggedIn = true
                reply("230 Logged in")
                return
            }
            failures += 1
            let allowed = server?.noteLogin(from: peerIP, ok: false) != false
            if failures >= FTPServer.maximumAuthFailures || !allowed {
                reply("421 Too many failed logins"); done = true
            } else {
                reply("530 Login incorrect")
            }
        }

        private func setType(_ arg: String) {
            switch arg.uppercased().first {
            case "A": ascii = true; reply("200 Type set to A")
            case "I", "L": ascii = false; reply("200 Type set to I")
            default: reply("504 Type not supported")
            }
        }

        private func changeDirectory(_ arg: String) {
            let path = arg.trimmingCharacters(in: .whitespaces)
            if ["", "/", ".", "/."].contains(path) { reply("250 Directory changed") }
            else { reply("550 No such directory") }
        }

        // MARK: Data endpoint

        private func closePassive() {
            if passive >= 0 { close(passive); passive = -1 }
        }

        private func openPassive(extended: Bool, arg: String) {
            closePassive(); active = nil
            if extended {
                let a = arg.trimmingCharacters(in: .whitespaces).uppercased()
                if a == "ALL" { reply("200 EPSV ALL ok"); return }
                if !a.isEmpty && a != "1" { reply("522 Network protocol not supported, use (1)"); return }
            }
            guard let local = FTPSocket.localIPv4(control) else { reply("425 Cannot open data connection"); return }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { reply("425 Cannot open data connection"); return }
            FTPSocket.configure(fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = local
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 1) == 0, let port = FTPSocket.localPort(fd) else {
                close(fd); reply("425 Cannot open data connection"); return
            }
            passive = fd
            if extended {
                reply("229 Entering Extended Passive Mode (|||\(port)|)")
            } else {
                var a = local
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &text, socklen_t(text.count))
                let host = FTPSocket.string(text).split(separator: ".").joined(separator: ",")
                reply("227 Entering Passive Mode (\(host),\(port >> 8),\(port & 0xFF))")
            }
        }

        private func parsePORT(_ arg: String) -> (String, UInt16)? {
            let n = arg.split(separator: ",", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 6, n.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return nil }
            let v = n.map { $0! }
            let port = v[4] * 256 + v[5]
            guard port > 0 else { return nil }
            return ("\(v[0]).\(v[1]).\(v[2]).\(v[3])", UInt16(port))
        }

        private func parseEPRT(_ arg: String) -> (String, UInt16)? {
            guard let delimiter = arg.first else { return nil }
            let parts = arg.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            // "", "1", "ip", "port", ""
            guard parts.count == 5, parts[1] == "1", let port = UInt16(parts[3]), port > 0 else { return nil }
            return (parts[2], port)
        }

        private func openActive(_ target: (String, UInt16)?) {
            guard let target else { reply("501 Bad address"); return }
            // FTP bounce: the address must be the client's own — never make
            // this Mac dial a third host on a client's say-so.
            guard target.0 == peerIP else { reply("501 The address must be your own"); return }
            closePassive()
            active = (target.0, target.1)
            reply("200 Command okay")
        }

        /// False (after a 425) when neither PASV/EPSV nor PORT/EPRT came first.
        private func requireEndpoint() -> Bool {
            guard active != nil || passive >= 0 else { reply("425 Use PASV or PORT first"); return false }
            return true
        }

        /// The data connection for the next transfer, or nil (a 425 is sent).
        private func acquireData() -> Int32? {
            defer { closePassive(); active = nil }
            if let target = active {
                guard let fd = FTPSocket.connect(ip: target.ip, port: target.port,
                                                 timeoutMs: 10_000, abort: { self.isAborted }) else {
                    reply("425 Cannot open data connection"); return nil
                }
                return fd
            }
            guard passive >= 0 else { reply("425 Use PASV or PORT first"); return nil }
            let deadline = Date().addingTimeInterval(FTPServer.dataConnectTimeout)
            while Date() < deadline, !isAborted {
                guard FTPSocket.poll(passive, events: Int16(POLLIN), timeoutMs: 250) > 0 else { continue }
                var peer = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let fd = withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(passive, $0, &length) }
                }
                guard fd >= 0 else { continue }
                // Another host that found the port: refuse it, keep waiting
                // for the real client.
                guard FTPSocket.ipv4String(of: peer) == peerIP else { close(fd); continue }
                FTPSocket.configure(fd)
                return fd
            }
            reply("425 Data connection not established")
            return nil
        }

        // MARK: Files

        private struct Facts { let url: URL; let size: Int64; let modified: Date }

        private func facts(of url: URL) -> Facts? {
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return Facts(url: url, size: Int64(info.st_size),
                         modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
        }

        private func fileFacts(_ arg: String, _ body: (Facts) -> Void) {
            guard let url = access.readURL(arg), let f = facts(of: url) else { reply("550 File not found"); return }
            body(f)
        }

        static func mdtm(_ date: Date) -> String {
            var t = time_t(date.timeIntervalSince1970)
            var parts = tm()
            gmtime_r(&t, &parts)
            return String(format: "%04d%02d%02d%02d%02d%02d", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
                          Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
        }

        private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        private func listDirectory(_ verb: String) {
            let files = access.listing().compactMap { facts(of: $0) }
            let text: String = files.map { f -> String in
                let name = f.url.lastPathComponent
                switch verb {
                case "NLST": return name
                case "MLSD": return "type=file;size=\(f.size);modify=\(Self.mdtm(f.modified)); \(name)"
                default:
                    var t = time_t(f.modified.timeIntervalSince1970)
                    var parts = tm()
                    gmtime_r(&t, &parts)
                    return String(format: "-rw-r--r--   1 sheepterm sheepterm %12lld %@ %2d  %04d %@",
                                  f.size, Self.months[Int(parts.tm_mon)], Int(parts.tm_mday),
                                  Int(parts.tm_year) + 1900, name)
                }
            }.map { $0 + "\r\n" }.joined()
            guard requireEndpoint(), reply("150 Here comes the directory listing") else { return }
            guard let data = acquireData() else { return }
            setData(data)
            let ok = FTPSocket.writeAll(data, Array(text.utf8), timeoutMs: Int32(FTPServer.dataStallTimeout * 1000),
                                        abort: { self.isAborted })
            finishData(data)
            reply(ok ? "226 Directory send OK" : "426 Connection closed; transfer aborted")
        }

        private func finishData(_ fd: Int32) {
            setData(-1)
            shutdown(fd, SHUT_WR)
            close(fd)
        }

        /// During a transfer: has the client sent ABOR (or hung up)? Other
        /// commands stay queued. This is what ends an upload the client gave up
        /// on even when its data socket closed as a clean EOF.
        private func clientAborted() -> Bool {
            if FTPSocket.poll(control, events: Int16(POLLIN), timeoutMs: 0) > 0 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = recv(control, &chunk, chunk.count, MSG_DONTWAIT)
                if n == 0 { done = true; return true }
                if n > 0 { buffer.append(contentsOf: chunk[..<n]) }
            }
            // A few queued commands are fine; a client streaming the control
            // connection during a transfer is cut off, not buffered without
            // bound (review 6.0 (4)).
            if buffer.count > FTPServer.maximumLine * 4 { done = true; return true }
            return buffer.split(separator: 0x0A).contains {
                String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("ABOR")
            }
        }

        // MARK: Progress

        private final class Meter: @unchecked Sendable {
            let token = UUID().uuidString
            var last: Int64 = 0
        }

        private func report(_ meter: Meter, name: String, upload: Bool, done: Int64, total: Int64,
                            state: ServerTransfer.State, detail: String = "", force: Bool = false) {
            if state == .active, !force, done - meter.last < 128 * 1024 { return }
            meter.last = done
            access.onProgress(ServerTransfer(token: meter.token, peer: peerIP, name: name, isUpload: upload,
                                             done: done, total: total, state: state, detail: detail))
        }

        // MARK: RETR

        private func retrieve(_ arg: String) {
            guard let url = access.readURL(arg), let f = facts(of: url),
                  let file = Optional(open(url.path, O_RDONLY)), file >= 0 else {
                reply("550 File not found"); return
            }
            defer { close(file) }
            let name = url.lastPathComponent
            let meter = Meter()
            guard requireEndpoint(), reply("150 Opening data connection") else { return }
            guard let data = acquireData() else { return }
            setData(data)
            report(meter, name: name, upload: false, done: 0, total: f.size, state: .active, force: true)
            var sent: Int64 = 0
            var ok = true
            var carryCR = false
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            while ok {
                if clientAborted() { ok = false; break }
                let count = read(file, &chunk, chunk.count)
                if count < 0 { if errno == EINTR { continue }; ok = false; break }
                if count == 0 { break }
                var out = Array(chunk[..<count])
                if ascii { out = FTPServer.toNetworkASCII(out, previousWasCR: &carryCR) }
                ok = FTPSocket.writeAll(data, out, timeoutMs: Int32(FTPServer.dataStallTimeout * 1000),
                                        abort: { self.isAborted })
                sent += Int64(count)
                report(meter, name: name, upload: false, done: sent, total: f.size, state: .active)
            }
            finishData(data)
            if ok {
                report(meter, name: name, upload: false, done: sent, total: f.size, state: .done, force: true)
                reply("226 Transfer complete")
            } else {
                report(meter, name: name, upload: false, done: sent, total: f.size, state: .failed,
                       detail: "connection closed", force: true)
                reply("426 Connection closed; transfer aborted")
            }
        }

        // MARK: STOR

        private func store(_ arg: String) {
            guard let target = access.writeURL(arg) else { reply("550 Not permitted"); return }
            // The free space less a reserve, like the TFTP and SSH servers.
            var fs = statfs()
            let free: Int64 = statfs(target.deletingLastPathComponent().path, &fs) == 0
                ? max(0, Int64(fs.f_bavail) * Int64(fs.f_bsize) - DownloadCap.reserve) : 0
            let cap = min(server?.maximumUploadBytes ?? 0, free)
            if cap <= 0 { announced = 0; reply("552 Not enough free space"); return }
            if announced > cap { announced = 0; reply("552 Too large"); return }
            announced = 0
            let name = target.lastPathComponent
            let temp = target.deletingLastPathComponent()
                .appendingPathComponent(".sheepterm-ftp-\(UUID().uuidString)")
            let file = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard file >= 0 else { reply("451 Cannot write"); return }
            var fileOpen = true
            func discard() {
                if fileOpen { close(file); fileOpen = false }
                unlink(temp.path)
            }
            let meter = Meter()
            setStoring(true)
            defer { setStoring(false) }
            guard requireEndpoint(), reply("150 Ready to receive") else { discard(); return }
            guard let data = acquireData() else { discard(); return }
            setData(data)
            report(meter, name: name, upload: true, done: 0, total: 0, state: .active, force: true)
            var received: Int64 = 0
            var pendingCR = false
            var failure: String?
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            let stall = Int32(FTPServer.dataStallTimeout * 1000)
            loop: while true {
                if isAborted || uploadWasAborted || clientAborted() { failure = "426 Transfer aborted"; break }
                switch FTPSocket.poll(data, events: Int16(POLLIN), timeoutMs: 250) {
                case 0:
                    if Date().timeIntervalSince(meterLastByte) > Double(stall) / 1000 {
                        failure = "426 Connection closed; transfer aborted"; break loop
                    }
                    continue
                case -1:
                    failure = "426 Connection closed; transfer aborted"; break loop
                default: break
                }
                let count = recv(data, &chunk, chunk.count, 0)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    failure = "426 Connection closed; transfer aborted"; break
                }
                meterLastByte = Date()
                var bytes = Array(chunk[..<count])
                if ascii { bytes = FTPServer.fromNetworkASCII(bytes, pendingCR: &pendingCR) }
                if !FTPSocket.writeToFile(file, bytes) { failure = "451 Write failed"; break }
                received += Int64(count)
                if received > cap { failure = "552 Exceeded the upload size limit"; break }
                report(meter, name: name, upload: true, done: received, total: 0, state: .active)
            }
            meterLastByte = Date()
            if failure == nil, uploadWasAborted { failure = "426 Transfer aborted" }
            if failure == nil, pendingCR, !FTPSocket.writeToFile(file, [0x0D]) { failure = "451 Write failed" }
            finishData(data)
            if let failure {
                discard()
                report(meter, name: name, upload: true, done: received, total: 0, state: .failed,
                       detail: failure.dropFirst(4).description, force: true)
                reply(failure)
                return
            }
            close(file); fileOpen = false
            // Writes still on, same folder? (Turned off or moved while the
            // bytes arrived: nothing lands.)
            guard access.writeURL(arg) == target else {
                unlink(temp.path)
                report(meter, name: name, upload: true, done: received, total: 0, state: .failed,
                       detail: "writes were turned off", force: true)
                reply("426 Transfer aborted")
                return
            }
            // RENAME_EXCL fails with EEXIST if the name is taken now: never replace.
            let moved = renamex_np(temp.path, target.path, UInt32(RENAME_EXCL))
            let code = errno
            if moved != 0 { unlink(temp.path) }
            guard moved == 0 else {
                report(meter, name: name, upload: true, done: received, total: 0, state: .failed,
                       detail: code == EEXIST ? "file exists" : "cannot write", force: true)
                reply(code == EEXIST ? "550 File exists" : "451 Cannot write")
                return
            }
            Quarantine.mark(target)      // it came from the network, like a download
            report(meter, name: name, upload: true, done: received, total: received, state: .done, force: true)
            reply("226 Transfer complete")
        }

        private var meterLastByte = Date()
    }

    /// Bare LF → CRLF (TYPE A on the wire); a CR already there stays.
    static func toNetworkASCII(_ bytes: [UInt8], previousWasCR: inout Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 40)
        for b in bytes {
            if b == 0x0A && !previousWasCR { out.append(0x0D) }
            out.append(b)
            previousWasCR = b == 0x0D
        }
        return out
    }

    /// CRLF → LF (TYPE A from the wire); a CR split from its LF by a chunk
    /// boundary is held back in `pendingCR`.
    static func fromNetworkASCII(_ bytes: [UInt8], pendingCR: inout Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if pendingCR {
                pendingCR = false
                if b != 0x0A { out.append(0x0D) }
            }
            if b == 0x0D { pendingCR = true } else { out.append(b) }
        }
        return out
    }

    /// Equality whose time depends only on the lengths (`==` stops at the first
    /// differing byte and leaks how much of a password was right).
    /// The File Server's one comparison (no early exit on a length
    /// mismatch — it leaked the length by timing; security review 6.0).
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        FileServerPlan.constantTimeEqual(a, b)
    }
}

// MARK: - Socket helpers (shared with FTPClient)

nonisolated enum FTPSocket {
    /// Non-blocking is NOT used: every wait is a `poll` slice. SIGPIPE off.
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// poll(2) on one descriptor: >0 ready (or hung up), 0 timeout, -1 error.
    static func poll(_ fd: Int32, events: Int16, timeoutMs: Int32) -> Int32 {
        var p = pollfd(fd: fd, events: events, revents: 0)
        let r = Darwin.poll(&p, 1, timeoutMs)
        if r < 0 { return errno == EINTR ? 0 : -1 }
        if r > 0, p.revents & Int16(POLLNVAL) != 0 { return -1 }
        return r
    }

    /// Sends every byte or returns false (error, stall for `timeoutMs`, abort).
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], timeoutMs: Int32, abort: () -> Bool) -> Bool {
        var offset = 0
        var idle = 0
        while offset < bytes.count {
            if abort() { return false }
            let ready = poll(fd, events: Int16(POLLOUT), timeoutMs: 250)
            if ready < 0 { return false }
            if ready == 0 {
                idle += 250
                if idle >= Int(timeoutMs) { return false }
                continue
            }
            let n = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress! + offset, bytes.count - offset, 0)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            idle = 0
            offset += n
        }
        return true
    }

    static func writeToFile(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }

    static func localPort(_ fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        return ok ? UInt16(bigEndian: address.sin_port) : nil
    }

    static func localIPv4(_ fd: Int32) -> in_addr? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        return ok && address.sin_family == sa_family_t(AF_INET) ? address.sin_addr : nil
    }

    /// Dotted IPv4 of a socket address (an IPv4-mapped IPv6 one included).
    static func ipv4String(of storage: sockaddr_storage) -> String? {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer -> String? in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> String? in
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { text(from: $0.pointee.sin_addr) }
                }
                if sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 -> String? in
                        var a = v6.pointee.sin6_addr
                        let mapped = withUnsafeBytes(of: &a) { b in
                            b.prefix(10).allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
                        }
                        guard mapped else { return nil }
                        let v4 = withUnsafeBytes(of: &a) { Array($0.suffix(4)) }
                        return v4.map(String.init).joined(separator: ".")
                    }
                }
                return nil
            }
        }
    }

    private static func text(from address: in_addr) -> String {
        var a = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count))
        return string(buffer)
    }

    static func string(_ c: [CChar]) -> String {
        String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Connects to a dotted IPv4 with a deadline; nil on failure.
    static func connect(ip: String, port: UInt16, timeoutMs: Int32, abort: () -> Bool) -> Int32? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(address: $0, length: socklen_t(MemoryLayout<sockaddr_in>.size), family: AF_INET,
                        timeoutMs: timeoutMs, abort: abort)
            }
        }
    }

    static func connect(address: UnsafePointer<sockaddr>, length: socklen_t, family: Int32,
                        timeoutMs: Int32, abort: () -> Bool) -> Int32? {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var result = Darwin.connect(fd, address, length)
        if result != 0, errno == EINPROGRESS {
            var waited: Int32 = 0
            while waited < timeoutMs, !abort() {
                let ready = poll(fd, events: Int16(POLLOUT), timeoutMs: 100)
                if ready < 0 { break }
                if ready > 0 {
                    var error: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
                    result = error == 0 ? 0 : -1
                    break
                }
                waited += 100
            }
            if waited >= timeoutMs { result = -1 }
        }
        guard result == 0 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}
