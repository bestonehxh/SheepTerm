import Darwin
import Foundation

/// The channel surface SCPServerHandler needs; the File Server's session
/// implements it over SSHServerConnection.
nonisolated protocol SCPChannelIO: AnyObject {
    /// Queues bytes; false when the channel is gone.
    func write(_ bytes: [UInt8]) -> Bool
    /// Blocks until at least one byte (≤ max) arrives; nil at EOF / death.
    func read(max: Int) -> [UInt8]?
    /// exit-status, EOF, CLOSE.
    func exit(_ code: Int32)
    /// File ▸ File Server stopped uploads.
    var uploadAborted: Bool { get }
}

/// The server side of the classic rcp/scp protocol over one exec channel:
/// `scp -f <path>` (a device pulls — `copy scp://…/file flash:`) and
/// `scp -t <path>` (a device pushes a backup). Control bytes are `\0` acks;
/// a file starts with `C<mode> <size> <name>\n`; `\1`/`\2` + a line is a
/// warning / fatal error. Ported from SheepDrop's SCPServerHandler (proven
/// against Aruba gear); names now resolve through `FileServerAccess`, `-r`
/// and directories are refused, uploads go through `ServerUpload` (temp +
/// RENAME_EXCL, size cap).
nonisolated final class SCPServerHandler {
    struct Command: Equatable {
        enum Mode: Equatable { case source, sink }
        let mode: Mode
        let path: String
    }

    private let io: SCPChannelIO
    private let command: String
    private let access: FileServerAccess
    private let peer: String
    private let uploads: UploadFactory
    private var pending: [UInt8] = []

    init(io: SCPChannelIO, command: String, access: FileServerAccess, peer: String, uploads: UploadFactory) {
        self.io = io
        self.command = command
        self.access = access
        self.peer = peer
        self.uploads = uploads
    }

    // MARK: Command line

    /// `scp [-v] [-p] [-d] [-q] (-f|-t) [--] <path>` → the request, or nil
    /// (refuse the exec): `-r`, any other flag, both or neither of -f/-t, no
    /// path or more than one, anything that is not scp.
    static func parse(_ line: String) -> Command? {
        guard let words = shellWords(line), let first = words.first,
              first == "scp" || first.hasSuffix("/scp") else { return nil }
        var mode: Command.Mode?
        var rest = words.dropFirst()
        while let word = rest.first, word.hasPrefix("-"), word.count > 1 {
            rest = rest.dropFirst()
            if word == "--" { break }
            for flag in word.dropFirst() {
                switch flag {
                case "f": if mode == .sink { return nil }; mode = .source
                case "t": if mode == .source { return nil }; mode = .sink
                case "p", "v", "d", "q": break
                default: return nil             // -r and everything else
                }
            }
        }
        guard let mode, rest.count == 1, let path = rest.first, !path.isEmpty else { return nil }
        return Command(mode: mode, path: path)
    }

    /// POSIX-shell word splitting with '…', "…" and backslash — what the
    /// remote shell would do to scp's argument (libssh clients quote the
    /// path, OpenSSH does not). Nil on an unterminated quote.
    static func shellWords(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(line).makeIterator()
        while let c = iterator.next() {
            switch c {
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                var closed = false
                while let d = iterator.next() { if d == "'" { closed = true; break }; current.append(d) }
                if !closed { return nil }
            case "\"":
                inWord = true
                var closed = false
                while let d = iterator.next() {
                    if d == "\"" { closed = true; break }
                    if d == "\\" {
                        guard let e = iterator.next() else { return nil }
                        if !"\"\\$`".contains(e) { current.append(d) }
                        current.append(e)
                    } else {
                        current.append(d)
                    }
                }
                if !closed { return nil }
            case "\\":
                inWord = true
                guard let e = iterator.next() else { return nil }
                current.append(e)
            default:
                inWord = true
                current.append(c)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    // MARK: Run

    func run() {
        guard let request = Self.parse(command) else {
            fatal("unsupported scp command")
            io.exit(1)
            return
        }
        let ok: Bool
        switch request.mode {
        case .source: ok = send(request.path)
        case .sink: ok = receive(into: request.path)
        }
        io.exit(ok ? 0 : 1)
    }

    // MARK: Source (the device pulls)

    private func send(_ raw: String) -> Bool {
        let display = FileServerPlan.lastComponent(of: raw)
        guard let url = SSHServerPath.read(raw, access) else {
            // Wait for the sink's go-ahead, then say why (scp prints it).
            _ = readAck()
            TransferReport.refused(peer: peer, name: display, isUpload: false, detail: "file not found", report: access.onProgress)
            warn("\(raw): No such file or directory")
            return false
        }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        var st = stat()
        guard fd >= 0, fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            if fd >= 0 { close(fd) }
            _ = readAck()
            warn("\(raw): cannot read")
            return false
        }
        defer { close(fd) }
        let size = Int64(st.st_size)
        guard readAck() else { return false }
        let report = TransferReport(peer: peer, name: url.lastPathComponent, isUpload: false, total: size,
                                    report: access.onProgress)
        guard io.write(Array("C0644 \(size) \(url.lastPathComponent)\n".utf8)), readAck() else {
            report.failed("the device refused the file")
            return false
        }
        var sent: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while sent < size {
            // Never past the size announced in the C line: a file that grew
            // under us would put the sink out of step.
            let want = Int(min(Int64(buffer.count), size - sent))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(sent)) }
            guard n > 0 else { break }
            guard io.write(Array(buffer[0..<n])) else { report.failed("connection lost"); return false }
            sent += Int64(n)
            report.progress(sent)
        }
        guard sent == size else {
            // The file shrank under us: pad so the sink stays in step, then
            // report the error in the trailing status.
            report.failed("short read")
            for chunk in Self.padding(size - sent) {
                guard io.write([UInt8](repeating: 0, count: chunk)) else { break }
            }
            warn("\(raw): read error")
            return false
        }
        guard io.write([0]), readAck() else { report.failed("the device did not confirm"); return false }
        report.done(size)
        return true
    }

    // MARK: Sink (the device pushes)

    private func receive(into raw: String) -> Bool {
        let targetIsFolder = SSHServerPath.isRoot(raw)
        guard targetIsFolder || !SSHServerPath.climbs(raw) else {
            fatal("\(raw): permission denied")
            return false
        }
        guard io.write([0]) else { return false }        // ready
        var received = 0
        while true {
            guard let line = readLine() else { return received > 0 }   // EOF: the source is done
            guard let kind = line.first else { fatal("protocol error"); return false }
            switch kind {
            case "T":                               // times (scp -p): ack, ignore
                guard io.write([0]) else { return false }
                continue
            case "C":
                break
            case "D", "E":
                fatal("directories are not supported")
                return false
            case "\u{01}", "\u{02}":                // the source reports an error
                return false
            default:
                fatal("protocol error")
                return false
            }
            // C<mode> <size> <name>
            let parts = line.dropFirst().split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let size = Int64(parts[1]), size >= 0 else { fatal("bad file header"); return false }
            let headerName = parts[2]
            guard !headerName.contains("/"), headerName != "..", headerName != "." else {
                fatal("\(headerName): bad file name")
                return false
            }
            let name = targetIsFolder ? headerName : raw
            let display = FileServerPlan.lastComponent(of: name)
            guard let target = SSHServerPath.write(name, access) else {
                TransferReport.refused(peer: peer, name: display, isUpload: true, detail: "refused", report: access.onProgress)
                fatal("\(display): permission denied")
                return false
            }
            let upload: ServerUpload
            switch uploads.begin(final: target, announced: size) {
            case .failure(let refusal):
                TransferReport.refused(peer: peer, name: display, isUpload: true, detail: refusal.description, report: access.onProgress)
                fatal("\(display): \(refusal.description)")
                return false
            case .success(let u):
                upload = u
            }
            let report = TransferReport(peer: peer, name: target.lastPathComponent, isUpload: true, total: size,
                                        report: access.onProgress)
            guard io.write([0]) else { upload.discard(); report.failed("connection lost"); return false }
            var got: Int64 = 0
            while got < size {
                if io.uploadAborted { upload.discard(); report.failed("stopped"); fatal("stopped"); return false }
                guard let chunk = readBytes(max: Int(min(size - got, 256 * 1024))) else {
                    upload.discard(); report.failed("connection lost"); return false
                }
                guard upload.write(chunk[...], at: got) else {
                    upload.discard(); report.failed("write failed"); fatal("write failed"); return false
                }
                got += Int64(chunk.count)
                report.progress(got)
            }
            // The source's trailing status: \0 = the bytes are the file.
            guard let status = readBytes(max: 1)?.first, status == 0 else {
                upload.discard()
                report.failed("the device reported an error")
                return false
            }
            if io.uploadAborted { upload.discard(); report.failed("stopped"); fatal("stopped"); return false }
            switch upload.commit() {
            case .success:
                report.done(size)
                received += 1
                guard io.write([0]) else { return false }
            case .failure(let refusal):
                report.failed(refusal.description)
                fatal("\(display): \(refusal.description)")
                return false
            }
        }
    }

    // MARK: Channel helpers

    private func readBytes(max: Int) -> [UInt8]? {
        if !pending.isEmpty {
            let n = min(max, pending.count)
            let out = Array(pending.prefix(n))
            pending.removeFirst(n)
            return out
        }
        return io.read(max: max)
    }

    /// A line up to `\n` (not included); nil at EOF. Capped at 4 KB.
    private func readLine() -> String? {
        var line: [UInt8] = []
        while true {
            if pending.isEmpty {
                guard let more = io.read(max: 4096) else { return nil }
                pending = more
            }
            if let newline = pending.firstIndex(of: 0x0A) {
                line += pending[..<newline]
                pending.removeFirst(newline + 1)
                return String(decoding: line, as: UTF8.self)
            }
            line += pending
            pending.removeAll()
            if line.count > 4096 { return nil }
        }
    }

    /// `\0` = go on; `\1`/`\2` + a line = the sink refused.
    private func readAck() -> Bool {
        guard let byte = readBytes(max: 1)?.first else { return false }
        if byte == 0 { return true }
        _ = readLine()
        return false
    }

    private func warn(_ message: String) {
        _ = io.write([1] + Array("scp: \(message)\n".utf8))
    }

    private func fatal(_ message: String) {
        _ = io.write([2] + Array("scp: \(message)\n".utf8))
    }
}

extension SCPServerHandler {
    /// The zero padding for a file that shrank under us, in pieces: one
    /// array the size of the gap was a multi-GB allocation (review 6.0 (4)).
    nonisolated static func padding(_ count: Int64, chunk: Int = 256 * 1024) -> [Int] {
        guard count > 0 else { return [] }
        let full = Int(count / Int64(chunk))
        let rest = Int(count % Int64(chunk))
        return Array(repeating: chunk, count: full) + (rest > 0 ? [rest] : [])
    }
}
