import Foundation

// The classic rcp protocol OpenSSH's scp speaks on an exec channel — the
// Files tab's blind fallback for devices that refuse the SFTP subsystem
// (some Aruba CX builds). Ported unchanged in behaviour from SheepDrop's
// SCPPushPull (proven against real switches): push is `scp -t <location>`,
// pull is `scp -f <path>`.
//
// Sans-I/O: SFTPClient's engine feeds channel data to `feed` and drains
// `outgoing` onto the channel. Queue-confined to that engine.

nonisolated struct SCPError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

nonisolated final class SCPTransfer {
    enum Mode { case push, pull }

    enum Step: Equatable {
        case awaitingExecReply
        case awaitingStartByte          // push: server's first status byte
        case awaitingFileConfirmation   // push: 0 after the C line
        case sendingData
        case awaitingFinalByte          // push: 0 after the data + \0
        case pullReadySent              // pull: \0 sent, waiting for T/C lines
        case pullData
        case pullTrailingZero
        case done
        case failed(String)

        var hasFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) var step: Step = .awaitingExecReply
    private(set) var done: Int64 = 0
    private(set) var total: Int64 = 0

    private let mode: Mode
    /// push: the destination directory ("flash:", "/tmp"); pull: the file path.
    private let location: String
    private let fileName: String
    private let fileSize: Int64
    private let source: FileHandle?
    private var target: FileHandle?

    /// Bytes to send on the channel now (drained and cleared by the owner).
    private var outgoingBuffer: [UInt8] = []
    /// Channel data that arrived before the exec reply (paramiko sends its
    /// first status byte in the same flight); replayed on approval.
    private var preApprovalBuffer: [UInt8] = []
    /// A pull C/T line split across channel packets, waiting for its "\n".
    private var partialLine: [UInt8] = []

    /// `scp -t <location>` / `scp -f <path>` — the exec command to run.
    /// The path is single-quoted for the remote shell, as libssh did: bare,
    /// a path with spaces broke and `;`, `$(…)` or backticks in it ran as
    /// commands on Unix hosts. Our own server strips the quotes.
    var command: String {
        let quoted = "'" + location.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return mode == .push ? "scp -t \(quoted)" : "scp -f \(quoted)"
    }

    var outgoing: [UInt8] {
        defer { outgoingBuffer.removeAll(keepingCapacity: true) }
        return outgoingBuffer
    }

    var isFinished: Bool { step == .done || step.hasFailed }

    var failureMessage: String? {
        if case .failed(let message) = step { return message }
        return nil
    }

    /// push: upload `localURL` as `name` into `location`.
    /// Pull only: a C line announcing more than this is refused (free space).
    private var maximumBytes: Int64 = .max

    init(push location: String, name: String, localURL: URL) throws {
        self.mode = .push
        self.location = location
        self.fileName = name
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SCPError("cannot read \(localURL.lastPathComponent)")
        }
        self.source = handle
        self.fileSize = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        self.target = nil
    }

    /// pull: download the remote file into `localURL` (already created).
    init(pull path: String, localURL: URL, maximumBytes: Int64 = .max) throws {
        self.maximumBytes = maximumBytes
        self.mode = .pull
        self.location = path
        self.fileName = ""
        self.source = nil
        self.fileSize = 0
        // The part file may not exist yet — create it empty.
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SCPError("cannot write \(localURL.lastPathComponent)")
        }
        self.target = handle
    }

    /// A transfer abandoned midway (cancel, dropped link) must not keep the
    /// file open: the caller deletes the part file next.
    deinit {
        try? source?.close()
        try? target?.close()
    }

    /// The channel request reply came back OK: the remote scp is running.
    func beginExecApproved() throws(SCPError) {
        guard step == .awaitingExecReply else { return }
        if mode == .pull {
            outgoingBuffer.append(0)        // tell the remote scp we are ready
            step = .pullReadySent
        } else {
            step = .awaitingStartByte       // push: next input is the status byte
        }
        if !preApprovalBuffer.isEmpty {
            let replay = preApprovalBuffer
            preApprovalBuffer = []
            try feed(replay)
        }
    }

    private var pushCLine: String {
        "C0644 \(fileSize) \(fileName)\n"
    }

    /// Feeds channel data. Throws on protocol errors and on the remote's
    /// status messages (byte 1 = warning, 2 = fatal, message until \n).
    func feed(_ bytes: [UInt8]) throws(SCPError) {
        // Input may beat the exec reply across the wire — hold it.
        if step == .awaitingExecReply {
            preApprovalBuffer.append(contentsOf: bytes)
            return
        }
        var rest = bytes[...]
        // .sendingData produces output with no input — the owner drives it
        // by calling feed([]) whenever its outgoing buffer drained empty.
        while !rest.isEmpty || step == .sendingData {
            switch step {
            case .awaitingStartByte:
                guard !rest.isEmpty else { return }
                let byte = rest.removeFirst()
                switch byte {
                case 0:
                    outgoingBuffer.append(contentsOf: Array(pushCLine.utf8))
                    step = .awaitingFileConfirmation
                case 1, 2:
                    throw SCPError(statusLine(&rest))
                default:
                    throw SCPError("scp protocol error (start byte \(byte))")
                }
            case .awaitingFileConfirmation:
                guard !rest.isEmpty else { return }
                let byte = rest.removeFirst()
                if byte == 0 {
                    total = fileSize
                    step = .sendingData
                } else if byte == 1 || byte == 2 {
                    throw SCPError(statusLine(&rest))
                } else {
                    throw SCPError("scp protocol error (confirm byte \(byte))")
                }
            case .sendingData:
                guard let source else {
                    throw SCPError("scp source file closed")
                }
                // Chunk the file out; the connection layer windows the bytes.
                // Return after one chunk so the owner can flush and read.
                let chunk: Data?
                do {
                    chunk = try source.read(upToCount: 96 * 1024)
                } catch {
                    throw SCPError("cannot read the local file: \(error)")
                }
                if let chunk, !chunk.isEmpty {
                    outgoingBuffer.append(contentsOf: chunk)
                    done += Int64(chunk.count)
                    if done >= fileSize {
                        try? source.close()
                        outgoingBuffer.append(0)    // end of file marker
                        step = .awaitingFinalByte
                    }
                } else {
                    try? source.close()
                    outgoingBuffer.append(0)
                    step = .awaitingFinalByte
                }
                return
            case .awaitingFinalByte:
                guard !rest.isEmpty else { return }
                let byte = rest.removeFirst()
                if byte == 0 {
                    step = .done
                } else if byte == 1 || byte == 2 {
                    throw SCPError(statusLine(&rest))
                } else {
                    throw SCPError("scp protocol error (final byte \(byte))")
                }
            case .pullReadySent, .pullData, .pullTrailingZero:
                try feedPull(&rest)
                return
            case .awaitingExecReply:
                throw SCPError("scp exec was not approved")
            case .done:
                return
            case .failed:
                return
            }
        }
    }

    /// Pull: lines end with \n — "T<mtime> 0 <atime> 0" (timestamps) then
    /// "C<mode> <size> <name>". Reply \0 after each accepted line; after C,
    /// read exactly <size> bytes, then one trailing 0 byte, and ack it.
    private func feedPull(_ rest: inout ArraySlice<UInt8>) throws(SCPError) {
        while step == .pullReadySent, !rest.isEmpty {
            guard let nl = rest.firstIndex(of: UInt8(ascii: "\n")) else {
                // Partial line: keep it — the rest arrives in the next packet.
                // (It used to be dropped, failing the transfer.)
                partialLine.append(contentsOf: rest)
                rest = rest[rest.endIndex...]
                if partialLine.count > 4096 { throw SCPError("scp protocol error (line too long)") }
                return
            }
            let line = String(decoding: partialLine + Array(rest[..<nl]), as: UTF8.self)
            partialLine.removeAll()
            rest = rest[rest.index(after: nl)...]
            if line.hasPrefix("T") {
                outgoingBuffer.append(0)            // accept the timestamps
            } else if line.hasPrefix("C") {
                let parts = line.split(separator: " ")
                guard parts.count >= 3, let size = Int64(parts[1]) else {
                    throw SCPError("unreadable scp file line “\(line)”")
                }
                guard size >= 0 else { throw SCPError("unreadable scp file line “\(line)”") }
                guard size <= maximumBytes else { throw SCPError("not enough free space for \(size) bytes") }
                total = size
                outgoingBuffer.append(0)
                step = .pullData
                if size == 0 {
                    // An empty file has no data phase — straight to the
                    // trailing \0 (it used to wait for bytes until timeout).
                    try? target?.close()
                    target = nil
                    step = .pullTrailingZero
                }
            } else if line.hasPrefix("E") {
                outgoingBuffer.append(0)            // directory end — ack, stay
            } else {
                throw SCPError(line.isEmpty ? "scp failed" : line)
            }
        }
        if step == .pullData, !rest.isEmpty {
            let remaining = Int(max(0, total - done))
            if remaining > 0 {
                let n = min(remaining, rest.count)
                let take = Array(rest.prefix(n))
                // A failed write (disk full) must fail the transfer, not be
                // counted as received and saved as a "complete" short file.
                do {
                    try target?.write(contentsOf: Data(take))
                } catch {
                    throw SCPError("cannot write the local file: \(error.localizedDescription)")
                }
                done += Int64(n)
                rest = rest.dropFirst(n)
            }
            if done >= total, total > 0 {
                try? target?.close()
                target = nil
                step = .pullTrailingZero
            }
        }
        if step == .pullTrailingZero, !rest.isEmpty {
            let byte = rest.removeFirst()
            guard byte == 0 else {
                throw SCPError("scp protocol error (trailing byte \(byte))")
            }
            outgoingBuffer.append(0)                // final ack
            step = .done
        }
    }

    /// The remote's status text after a warning/fatal byte (to end of line).
    private func statusLine(_ rest: inout ArraySlice<UInt8>) -> String {
        if let nl = rest.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: rest[..<nl], as: UTF8.self)
            rest = rest[rest.index(after: nl)...]
            step = .failed(line)
            return line.isEmpty ? "scp reported a failed transfer" : line
        }
        let line = String(decoding: rest, as: UTF8.self)
        rest = rest[rest.endIndex...]
        step = .failed(line)
        return line.isEmpty ? "scp reported a failed transfer" : line
    }
}
