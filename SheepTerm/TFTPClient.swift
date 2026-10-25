import Darwin
import Foundation

/// TFTP client for the Files tab (RFC 1350 + blksize/tsize, RFC 2347–2349):
/// get a file from, or put one on, a TFTP server — a lab server, another
/// switch, a PXE box. TFTP cannot list, so `canBrowse` is false and the tab
/// shows a get/put form. Blocking BSD sockets on one queue per transfer;
/// every call is async and honours Task cancellation.
nonisolated final class TFTPClient: RemoteFileClient, @unchecked Sendable {
    let host: String
    let port: Int
    var canBrowse: Bool { false }

    /// Block size asked for (the server may answer smaller, or not at all).
    static let blockSize = 1428          // fits a 1500-byte MTU with IP/UDP/TFTP headers
    static let timeout: TimeInterval = 2
    static let retries = 5
    /// A download larger than this is refused — nothing on a TFTP server
    /// needs more, and the transfer would never end on a wrap bug.
    static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024

    private init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Resolves the server; nothing is sent until the first transfer.
    static func connect(_ endpoint: RemoteEndpoint) async throws -> TFTPClient {
        let client = TFTPClient(host: endpoint.host, port: endpoint.port == 0 ? 69 : endpoint.port)
        guard try await client.resolve() != nil else { throw RemoteFileError.connection("Cannot resolve \(endpoint.host)") }
        return client
    }

    func home() async throws -> String { "/" }
    func list(_ path: String) async throws -> [RemoteEntry] { throw RemoteFileError.unsupported("TFTP cannot list a directory") }
    func makeDirectory(_ path: String) async throws { throw RemoteFileError.unsupported("TFTP cannot make a directory") }
    func remove(_ path: String, isDirectory: Bool) async throws { throw RemoteFileError.unsupported("TFTP cannot delete") }
    func rename(_ from: String, to: String) async throws { throw RemoteFileError.unsupported("TFTP cannot rename") }
    func close() {}

    // MARK: Transfers

    func download(_ remotePath: String, to local: URL, progress: @escaping TransferProgress) async throws {
        let name = Self.wireName(remotePath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw RemoteFileError.alreadyExists("\(local.lastPathComponent) is a folder")
        }
        let temp = local.deletingLastPathComponent().appendingPathComponent(".sheepterm-tftp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            throw RemoteFileError.permissionDenied(local.deletingLastPathComponent().path)
        }
        do {
            // Never past the free space less a reserve (a hostile server
            // streaming forever must not fill the disk), nor past 4 GB.
            let limit = min(Self.maximumBytes, DownloadCap.bytes(for: local))
            try await run { cancelled in
                try self.receive(name: name, into: handle, limit: limit, progress: progress, cancelled: cancelled)
            }
            try handle.close()
            // A plain rename (as SFTP / FTP): replaces a file the user agreed
            // to replace, and fails on a folder instead of swapping with it.
            guard Darwin.rename(temp.path, local.path) == 0 else {
                throw RemoteFileError.permissionDenied(local.path)
            }
            Quarantine.mark(local)
        } catch {
            try? handle.close()
            unlink(temp.path)
            throw error
        }
    }

    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress) async throws {
        let name = Self.wireName(remotePath)
        guard let handle = try? FileHandle(forReadingFrom: local) else { throw RemoteFileError.notFound(local.path) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? nil
        try await run { cancelled in
            try self.send(name: name, from: handle, size: size, progress: progress, cancelled: cancelled)
        }
    }

    /// TFTP names are plain; a leading "/" is kept (some servers want it).
    static func wireName(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    // MARK: Plumbing

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// Runs a blocking transfer off the cooperative pool; a Task cancel
    /// raises the flag the loop checks between datagrams.
    private func run(_ body: @escaping @Sendable (_ cancelled: @Sendable () -> Bool) throws -> Void) async throws {
        let flag = Flag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "sheepterm.tftp.client").async {
                    do {
                        try body { flag.value }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.raise()
        }
    }

    private func resolve() async throws -> sockaddr_storage? {
        let host = self.host, port = self.port
        return await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_DGRAM
            hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
            defer { freeaddrinfo(result) }
            var storage = sockaddr_storage()
            memcpy(&storage, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
            return storage
        }.value
    }

    private struct Socket {
        let fd: Int32
        var server: sockaddr_storage
        /// The server's transfer TID, locked on its first reply.
        var peer: sockaddr_storage?

        static func open(to address: sockaddr_storage) throws -> Socket {
            let fd = socket(Int32(address.ss_family), SOCK_DGRAM, 0)
            guard fd >= 0 else { throw RemoteFileError.connection("socket: \(String(cString: strerror(errno)))") }
            var tv = timeval(tv_sec: Int(TFTPClient.timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return Socket(fd: fd, server: address)
        }

        func send(_ bytes: [UInt8]) {
            var target = peer ?? server
            let length = socklen_t(target.ss_family == UInt8(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, length) }
            }
        }

        /// The next datagram from the server's host (a stray from another
        /// address or, once locked, another port is dropped — RFC 1350 TID
        /// rule). Nil on timeout.
        mutating func receive() -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: 65536)
            // A flood of strays must not keep the caller from checking for
            // cancel: after this many, report a timeout and let it look.
            var strays = 0
            while true {
                strays += 1
                // [] = "nothing for us yet", NOT a timeout: strays must
                // neither kill a live transfer nor keep cancel from landing.
                if strays > 64 { return [] }
                var from = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
                }
                guard n >= 0 else { return nil }
                guard Self.sameHost(from, server) else { continue }
                if let peer {
                    guard Self.port(of: from) == Self.port(of: peer) else {
                        // Another TID: RFC 1350 says answer ERROR 5 to it.
                        var other = from
                        let err: [UInt8] = [0, 5, 0, 5] + Array("unknown transfer ID".utf8) + [0]
                        _ = withUnsafePointer(to: &other) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, err, err.count, 0, $0, length) }
                        }
                        continue
                    }
                } else {
                    peer = from
                }
                return Array(buffer[0..<n])
            }
        }

        static func port(of a: sockaddr_storage) -> UInt16 {
            var a = a
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        }

        static func sameHost(_ a: sockaddr_storage, _ b: sockaddr_storage) -> Bool {
            guard a.ss_family == b.ss_family else { return false }
            var a = a, b = b
            if a.ss_family == UInt8(AF_INET) {
                let x = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr } }
                let y = withUnsafePointer(to: &b) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr } }
                return x == y
            }
            let x = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr } }
            let y = withUnsafePointer(to: &b) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr } }
            return withUnsafeBytes(of: x) { xb in withUnsafeBytes(of: y) { yb in xb.elementsEqual(yb) } }
        }
    }

    private func request(_ opcode: UInt8, name: String, tsize: Int64?) -> [UInt8] {
        var p: [UInt8] = [0, opcode] + Array(name.utf8) + [0] + Array("octet".utf8) + [0]
        p += Array("blksize".utf8) + [0] + Array(String(Self.blockSize).utf8) + [0]
        p += Array("tsize".utf8) + [0] + Array(String(tsize ?? 0).utf8) + [0]
        return p
    }

    private static func errorText(_ packet: [UInt8]) -> RemoteFileError {
        let code = packet.count >= 4 ? Int(packet[2]) << 8 | Int(packet[3]) : 0
        let text = packet.count > 4 ? String(decoding: packet[4...].prefix { $0 != 0 }, as: UTF8.self) : ""
        switch code {
        case 1: return .notFound(text.isEmpty ? "file not found" : text)
        case 2: return .permissionDenied(text.isEmpty ? "access violation" : text)
        case 6: return .alreadyExists(text.isEmpty ? "file exists" : text)
        default: return .remote(text.isEmpty ? "TFTP error \(code)" : text)
        }
    }

    /// Options the server acknowledged (OACK), name → value.
    private static func options(_ packet: [UInt8]) -> [String: String] {
        let fields = packet.dropFirst(2).split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var out: [String: String] = [:]
        var i = 0
        while i + 1 < fields.count { out[fields[i].lowercased()] = fields[i + 1]; i += 2 }
        return out
    }

    private func address() throws -> sockaddr_storage {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            throw RemoteFileError.connection("Cannot resolve \(host)")
        }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        memcpy(&storage, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
        return storage
    }

    private func receive(name: String, into handle: FileHandle, limit: Int64, progress: TransferProgress,
                         cancelled: () -> Bool) throws {
        var socket = try Socket.open(to: try address())
        defer { Darwin.close(socket.fd) }
        var last = request(1, name: name, tsize: 0)
        socket.send(last)
        var blockSize = 512
        var total: Int64?
        var expected: UInt16 = 1
        var written: Int64 = 0
        var tries = 0
        var lastReport = Date.distantPast
        var first = true
        while true {
            if cancelled() {
                socket.send([0, 5, 0, 0] + Array("cancelled".utf8) + [0])
                throw RemoteFileError.cancelled
            }
            let received = socket.receive()
            if received?.isEmpty == true { continue }      // strays only: look at cancel, keep going
            guard let packet = received, packet.count >= 2 else {
                tries += 1
                guard tries <= Self.retries else { throw RemoteFileError.connection("TFTP server did not answer") }
                socket.send(last)
                continue
            }
            switch packet[1] {
            case 6 where first:   // OACK
                let o = Self.options(packet)
                blockSize = o["blksize"].flatMap(Int.init) ?? 512
                // RFC 2348: the server may only lower it.
                guard (8...Self.blockSize).contains(blockSize) else { throw RemoteFileError.remote("TFTP server answered a bad block size") }
                total = o["tsize"].flatMap(Int64.init)
                if let total, total > limit { throw RemoteFileError.remote(total > Self.maximumBytes ? "File too large" : "Not enough free space for \(name)") }
                last = [0, 4, 0, 0]
                socket.send(last)
                first = false
                tries = 0
            case 3 where packet.count >= 4:
                first = false
                let block = UInt16(packet[2]) << 8 | UInt16(packet[3])
                if block == expected {
                    let payload = packet[4...]
                    try handle.write(contentsOf: payload)
                    written += Int64(payload.count)
                    guard written <= limit else { throw RemoteFileError.remote(written > Self.maximumBytes ? "File too large" : "Not enough free space for \(name)") }
                    last = [0, 4, UInt8(block >> 8), UInt8(block & 0xFF)]
                    socket.send(last)
                    expected &+= 1
                    tries = 0
                    if Date().timeIntervalSince(lastReport) > 0.1 {
                        progress(written, total)
                        lastReport = Date()
                    }
                    if payload.count < blockSize {
                        progress(written, total ?? written)
                        return
                    }
                } else {
                    socket.send(last)     // duplicate: re-ACK what we have
                }
            case 5:
                throw Self.errorText(packet)
            default:
                continue
            }
        }
    }

    private func send(name: String, from handle: FileHandle, size: Int64?, progress: TransferProgress,
                      cancelled: () -> Bool) throws {
        var socket = try Socket.open(to: try address())
        defer { Darwin.close(socket.fd) }
        var last = request(2, name: name, tsize: size)
        socket.send(last)
        var blockSize = 512
        var block: UInt16 = 0
        var sent: Int64 = 0
        var tries = 0
        var finalSent = false
        var lastReport = Date.distantPast
        var first = true
        func nextData() throws {
            let chunk = try handle.read(upToCount: blockSize) ?? Data()
            block &+= 1
            last = [0, 3, UInt8(block >> 8), UInt8(block & 0xFF)] + Array(chunk)
            sent += Int64(chunk.count)
            finalSent = chunk.count < blockSize
            socket.send(last)
            tries = 0
        }
        while true {
            if cancelled() {
                socket.send([0, 5, 0, 0] + Array("cancelled".utf8) + [0])
                throw RemoteFileError.cancelled
            }
            let received = socket.receive()
            if received?.isEmpty == true { continue }      // strays only: look at cancel, keep going
            guard let packet = received, packet.count >= 2 else {
                tries += 1
                guard tries <= Self.retries else { throw RemoteFileError.connection("TFTP server did not answer") }
                socket.send(last)
                continue
            }
            switch packet[1] {
            case 6 where first:
                blockSize = Self.options(packet)["blksize"].flatMap(Int.init) ?? 512
                guard (8...Self.blockSize).contains(blockSize) else { throw RemoteFileError.remote("TFTP server answered a bad block size") }
                first = false
                try nextData()
            case 4 where packet.count >= 4:
                first = false
                let acked = UInt16(packet[2]) << 8 | UInt16(packet[3])
                guard acked == block else { continue }   // stale ACK: never resend on it
                if finalSent {
                    progress(sent, size ?? sent)
                    return
                }
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    progress(sent, size)
                    lastReport = Date()
                }
                try nextData()
            case 5:
                throw Self.errorText(packet)
            default:
                continue
            }
        }
    }
}
