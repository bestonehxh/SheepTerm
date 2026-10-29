import Darwin
import Foundation

/// TFTP client for the Files tab (RFC 1350 + blksize/tsize, RFC 2347–2349):
/// get a file from, or put one on, a TFTP server — a lab server, another
/// switch, a PXE box. TFTP cannot list, so `canBrowse` is false and the tab
/// shows a get/put form. The protocol is `TFTPTransfer` (TFTPProtocol.swift,
/// shared with the server); this is a BSD UDP socket polled on one queue per
/// transfer. Every call is async and honours Task cancellation.
nonisolated final class TFTPClient: RemoteFileClient, @unchecked Sendable {
    let host: String
    let port: Int
    var canBrowse: Bool { false }

    /// Block size asked for (the server may answer smaller, or not at all).
    static let blockSize = 1428          // fits a 1500-byte MTU with IP/UDP/TFTP headers
    static let timeout: TimeInterval = 2
    static let retries = 5
    /// No step forward (a new block, the right ACK) for this long ends the
    /// transfer, whatever else arrives: strays from another port, or a server
    /// repeating an old block, used to keep it alive forever (review 6.0 (4)).
    static var stallLimit: TimeInterval { timeout * Double(retries + 1) }
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

    func download(_ remotePath: String, to local: URL, replacing: Bool, progress: @escaping TransferProgress) async throws {
        let name = Self.wireName(remotePath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw RemoteFileError.alreadyExists("\(local.lastPathComponent) is a folder")
        }
        let temp = local.deletingLastPathComponent().appendingPathComponent(".sheepterm-tftp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            throw RemoteFileError.permissionDenied(local.deletingLastPathComponent().lastPathComponent)
        }
        do {
            // Never past the free space less a reserve (a hostile server
            // streaming forever must not fill the disk), nor past 4 GB.
            let limit = min(Self.maximumBytes, DownloadCap.bytes(for: local))
            try await run { cancelled, succeeded in
                try self.receive(name: name, into: handle, limit: limit, progress: progress, cancelled: cancelled, succeeded: succeeded)
            }
            try handle.close()
            // Marked, then renamed: over a file only when the user said
            // Replace; never swapped with a folder.
            try DownloadCommit.commit(temp, to: local, replacing: replacing)
        } catch {
            try? handle.close()
            unlink(temp.path)
            throw error
        }
    }

    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress) async throws {
        let name = Self.wireName(remotePath)
        guard let handle = try? FileHandle(forReadingFrom: local) else { throw RemoteFileError.notFound(local.lastPathComponent) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? nil
        try await run { cancelled, _ in
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
        /// True the first time only.
        func raise() -> Bool { lock.withLock { defer { raised = true }; return !raised } }
    }

    /// Runs a blocking transfer off the cooperative pool; a Task cancel
    /// raises the flag the loop checks at least every 250 ms. The body may
    /// call `succeeded` before it returns: the caller goes on at once while
    /// the body stays a little longer (a download dallies for a lost final
    /// ACK, RFC 1350 §6) on its own queue.
    private func run(_ body: @escaping @Sendable (_ cancelled: @Sendable () -> Bool,
                                                  _ succeeded: @Sendable () -> Void) throws -> Void) async throws {
        let flag = Flag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = Flag()
                DispatchQueue(label: "sheepterm.tftp.client").async {
                    do {
                        try body({ flag.value }, { if resumed.raise() { continuation.resume() } })
                        if resumed.raise() { continuation.resume() }
                    } catch {
                        if resumed.raise() { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: {
            _ = flag.raise()
        }
    }

    private func resolve() async throws -> UDPAddress? {
        let host = self.host, port = self.port
        return await Task.detached { UDPAddress.resolve(host, port: port) }.value
    }

    private static func request(write: Bool, name: String, tsize: Int64?) -> TFTPRequest {
        TFTPRequest(isWrite: write, name: name, mode: "octet",
                    options: [TFTPOption("blksize", String(blockSize)), TFTPOption("tsize", String(tsize ?? 0))])
    }

    /// A refusal from the server as the Files tab shows it.
    static func error(code: UInt16, message text: String) -> RemoteFileError {
        switch code {
        case TFTPErrorCode.fileNotFound: return .notFound(text.isEmpty ? "file not found" : text)
        case TFTPErrorCode.accessViolation: return .permissionDenied(text.isEmpty ? "access violation" : text)
        case TFTPErrorCode.fileExists: return .alreadyExists(text.isEmpty ? "file exists" : text)
        default: return .remote(text.isEmpty ? "TFTP error \(code)" : text)
        }
    }

    /// Drives one `TFTPTransfer` over a UDP socket to the server: the
    /// protocol decisions are all the machine's (TFTPProtocol.swift).
    /// `deliver` takes a download's bytes; `source` feeds an upload.
    private func drive(_ machine: TFTPTransfer, name: String, limit: Int64,
                       source: TFTPTransfer.Source, deliver: (Data) throws -> Void,
                       progress: TransferProgress, total: (TFTPTransfer) -> Int64?,
                       cancelled: () -> Bool, succeeded: () -> Void) throws {
        guard let server = UDPAddress.resolve(host, port: port) else { throw RemoteFileError.connection("Cannot resolve \(host)") }
        let fd = socket(server.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RemoteFileError.connection("socket: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var m = machine
        var outcome: TFTPTransfer.Outcome?
        var lastReport = Date.distantPast
        var buffer = [UInt8](repeating: 0, count: 65536)

        func perform(_ actions: [TFTPTransfer.Action]) throws {
            var queue = actions[...]
            while let action = queue.popFirst() {
                switch action {
                case .send(let bytes, let port):
                    UDPSocket.send(fd, bytes, to: server.withPort(port))
                case .deliver(let payload):
                    do { try deliver(payload) } catch {
                        queue = m.abort(code: TFTPErrorCode.diskFull, message: "write failed")[...]
                        outcome = .failed(.aborted(code: TFTPErrorCode.diskFull, message: "write failed"))
                        for case .send(let bytes, let port) in queue { UDPSocket.send(fd, bytes, to: server.withPort(port)) }
                        throw error
                    }
                case .progress(let done):
                    if Date().timeIntervalSince(lastReport) > 0.1 {
                        progress(done, total(m))
                        lastReport = Date()
                    }
                case .lastBlock:
                    // The download's temp is committed by the caller once we
                    // return; the final ACK goes now.
                    queue = (m.commit(now: UDPSocket.now) + queue)[...]
                case .finished(let result):
                    outcome = result
                }
            }
        }

        try perform(m.start(now: UDPSocket.now, source: source))
        while outcome == nil {
            if cancelled() {
                try perform(m.abort(code: TFTPErrorCode.notDefined, message: "cancelled"))
                throw RemoteFileError.cancelled
            }
            try wait(fd, until: m.nextDeadline)
            // Strays from another host are dropped here; another port of the
            // server's host is the machine's (ERROR 5, the transfer goes on).
            for _ in 0..<64 {
                guard outcome == nil, case .datagram(let bytes, let from) = UDPSocket.receive(fd, into: &buffer) else { break }
                guard from.sameHost(server) else { continue }
                try perform(m.receive(bytes, from: from.port, now: UDPSocket.now, source: source))
            }
            if outcome == nil, let deadline = m.nextDeadline, UDPSocket.now >= deadline {
                try perform(m.tick(now: UDPSocket.now))
            }
        }
        switch outcome {
        case .done(let bytes)?:
            progress(bytes, total(m) ?? bytes)
            succeeded()
            // Dally: a server that lost our final ACK repeats its last block;
            // it gets the ACK again instead of reporting a failure.
            while !m.isClosed {
                try wait(fd, until: m.nextDeadline)
                while case .datagram(let bytes, let from) = UDPSocket.receive(fd, into: &buffer) {
                    guard from.sameHost(server) else { continue }
                    try perform(m.receive(bytes, from: from.port, now: UDPSocket.now, source: source))
                }
                try perform(m.tick(now: UDPSocket.now))
            }
        case .failed(let failure)?:
            switch failure {
            case .timedOut: throw RemoteFileError.connection("TFTP server did not answer")
            case .peer(let code, let message): throw Self.error(code: code, message: message)
            case .badOption: throw RemoteFileError.remote("TFTP server answered a bad block size")
            case .tooLarge(let announced):
                let large = announced.map { $0 > Self.maximumBytes } ?? (limit >= Self.maximumBytes)
                throw RemoteFileError.remote(large ? "File too large" : "Not enough free space for \(name)")
            case .sizeMismatch(let got, let expected): throw RemoteFileError.remote("Got \(got) of \(expected) bytes")
            case .aborted(_, let message): throw RemoteFileError.remote(message)
            }
        case nil:
            break
        }
    }

    /// Waits for a datagram, the machine's deadline, or 250 ms (the cancel
    /// check), whichever comes first.
    private func wait(_ fd: Int32, until deadline: TimeInterval?) throws {
        var wait = 0.25
        if let deadline { wait = min(wait, max(0, deadline - UDPSocket.now)) }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&p, 1, Int32((wait * 1000).rounded(.up)))
    }

    private func receive(name: String, into handle: FileHandle, limit: Int64, progress: TransferProgress,
                         cancelled: () -> Bool, succeeded: () -> Void) throws {
        let machine = TFTPTransfer(role: .receiver, opening: .request(Self.request(write: false, name: name, tsize: 0), askedBlockSize: Self.blockSize),
                                   peerPort: UInt16(clamping: port), limit: limit, policy: .client)
        try drive(machine, name: name, limit: limit, source: { _, _ in Data() },
                  deliver: { try handle.write(contentsOf: $0) }, progress: progress, total: { $0.announcedSize },
                  cancelled: cancelled, succeeded: succeeded)
    }

    private func send(name: String, from handle: FileHandle, size: Int64?, progress: TransferProgress,
                      cancelled: () -> Bool) throws {
        let machine = TFTPTransfer(role: .sender, opening: .request(Self.request(write: true, name: name, tsize: size), askedBlockSize: Self.blockSize),
                                   peerPort: UInt16(clamping: port), policy: .client)
        try drive(machine, name: name, limit: .max, source: { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }, deliver: { _ in }, progress: progress, total: { _ in size }, cancelled: cancelled, succeeded: {})
    }
}
