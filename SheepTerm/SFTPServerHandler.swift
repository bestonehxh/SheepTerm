import Darwin
import Foundation
import SheepSSH

/// One client's SFTP (v3) requests against the File Server's view: a root
/// `/` that lists `access.listing()`, names that resolve through
/// `access.readURL` / `access.writeURL` (SSHServerPath), and nothing else.
/// Ported from SheepDrop's SFTPRequestHandler; the served-root-folder model
/// is gone, and so is every operation that changes what is already on the
/// Mac: REMOVE / RENAME / MKDIR / RMDIR / SETSTAT / FSETSTAT / SYMLINK answer
/// PERMISSION_DENIED, anything else unknown OP_UNSUPPORTED.
///
/// Runs on its connection's thread; the session hands it whole packets
/// (length prefix removed) and sends back what `respond` returns.
nonisolated final class SFTPServerHandler {
    private enum FX {
        static let ok: UInt32 = 0
        static let eof: UInt32 = 1
        static let noSuchFile: UInt32 = 2
        static let permissionDenied: UInt32 = 3
        static let failure: UInt32 = 4
        static let badMessage: UInt32 = 5
        static let opUnsupported: UInt32 = 8
    }

    private final class OpenHandle {
        enum Kind {
            case directory(entries: [URL], sent: Bool)
            case read(fd: Int32, report: TransferReport)
            case write(ServerUpload, report: TransferReport)
        }
        var kind: Kind
        let name: String
        var bytes: Int64 = 0
        var total: Int64 = 0
        init(kind: Kind, name: String) { self.kind = kind; self.name = name }
    }

    static let maximumHandles = 16
    /// The most one READ returns (clients ask again for the rest).
    static let maximumRead = 64 * 1024

    private let access: FileServerAccess
    private let peer: String
    private let uploads: UploadFactory
    private var handles: [[UInt8]: OpenHandle] = [:]
    private var nextHandle: UInt32 = 0

    init(access: FileServerAccess, peer: String, uploads: UploadFactory) {
        self.access = access
        self.peer = peer
        self.uploads = uploads
    }

    // MARK: Requests

    func respond(to payload: [UInt8]) -> [UInt8] {
        guard let type = payload.first else { return [] }
        var r = SSHReader(payload, from: 1)
        if type == 1 {                          // INIT: our version, no extensions
            var w = SSHWriter()
            w.writeByte(2)
            w.writeUInt32(3)
            return framed(w.bytes)
        }
        guard let id = try? r.readUInt32() else { return [] }
        do {
            switch type {
            case 3: return try open(id, &r)
            case 4: return try closeHandle(id, &r)
            case 5: return try readFile(id, &r)
            case 6: return try writeFile(id, &r)
            case 7, 17: return try replyStat(id, &r)         // LSTAT / STAT
            case 8: return try replyFStat(id, &r)
            case 11: return try openDirectory(id, &r)
            case 12: return try readDirectory(id, &r)
            case 16: return try realpath(id, &r)
            case 9, 10, 13, 14, 15, 18, 20:             // SETSTAT FSETSTAT REMOVE MKDIR RMDIR RENAME SYMLINK
                return status(id, FX.permissionDenied, "Permission denied: this server never changes files on the Mac")
            default:
                return status(id, FX.opUnsupported, "Operation unsupported")
            }
        } catch {
            return status(id, FX.badMessage, "Bad message")
        }
    }

    /// Releases every handle the client left open: reads stop, unfinished
    /// uploads are discarded, their bars fail.
    func closeAll(reason: String) {
        for box in handles.values {
            switch box.kind {
            case .read(let fd, let report):
                close(fd)
                if box.total > 0, box.bytes >= box.total { report.done(box.total) } else { report.failed(reason) }
            case .write(let upload, let report):
                upload.discard()
                report.failed(reason)
            case .directory:
                break
            }
        }
        handles.removeAll()
    }

    /// File ▸ File Server's "stop uploads": every write handle ends now.
    func abortWrites() {
        for (key, box) in handles {
            guard case .write(let upload, let report) = box.kind else { continue }
            upload.discard()
            report.failed("stopped")
            handles[key] = nil
        }
    }

    // MARK: Handlers

    private func realpath(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let path = SSHServerPath.canonical(try r.readUTF8())
        return name(id, [(path, path == "/" ? Self.directoryAttributes : nil)])
    }

    private func replyStat(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let raw = try r.readUTF8()
        if SSHServerPath.isRoot(raw) { return attrs(id, Self.directoryAttributes) }
        guard let url = SSHServerPath.read(raw, access), let a = Self.attributes(of: url) else {
            return status(id, FX.noSuchFile, "No such file")
        }
        return attrs(id, a)
    }

    private func replyFStat(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        guard let box = handles[try r.readString()] else { return status(id, FX.failure, "Bad handle") }
        switch box.kind {
        case .directory: return attrs(id, Self.directoryAttributes)
        case .read(let fd, _):
            var st = Darwin.stat()
            guard Darwin.fstat(fd, &st) == 0 else { return status(id, FX.failure, "stat failed") }
            return attrs(id, Attributes(size: UInt64(st.st_size), isDirectory: false, mtime: UInt32(clamping: st.st_mtimespec.tv_sec)))
        case .write(let upload, _):
            return attrs(id, Attributes(size: UInt64(upload.size), isDirectory: false, mtime: UInt32(Date().timeIntervalSince1970)))
        }
    }

    private func openDirectory(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let raw = try r.readUTF8()
        guard SSHServerPath.isRoot(raw) else {
            // The served name is a file; everything else does not exist.
            return status(id, SSHServerPath.read(raw, access) == nil ? FX.noSuchFile : FX.failure, "Not a directory")
        }
        guard let handle = newHandle() else { return status(id, FX.failure, "Too many open handles") }
        handles[handle] = OpenHandle(kind: .directory(entries: access.listing(), sent: false), name: "/")
        return handleReply(id, handle)
    }

    private func readDirectory(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        guard let box = handles[try r.readString()], case .directory(let entries, let sent) = box.kind else {
            return status(id, FX.failure, "Bad handle")
        }
        let rows = entries.compactMap { url in Self.attributes(of: url).map { (url.lastPathComponent, $0) } }
        if sent || rows.isEmpty { return status(id, FX.eof, "End of directory") }
        box.kind = .directory(entries: entries, sent: true)
        return name(id, rows.map { ($0.0, Optional($0.1)) })
    }

    private func open(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let raw = try r.readUTF8()
        let flags = try r.readUInt32()
        let announced = Self.announcedSize(&r)
        let display = FileServerPlan.lastComponent(of: raw)
        guard handles.count < Self.maximumHandles else { return status(id, FX.failure, "Too many open handles") }
        if flags & 0x2 != 0 {                   // SSH_FXF_WRITE
            guard let target = SSHServerPath.write(raw, access) else {
                TransferReport.refused(peer: peer, name: display, isUpload: true, detail: "refused", report: access.onProgress)
                return status(id, FX.permissionDenied, "Permission denied")
            }
            switch uploads.begin(final: target, announced: announced) {
            case .failure(let refusal):
                TransferReport.refused(peer: peer, name: display, isUpload: true, detail: refusal.description, report: access.onProgress)
                return status(id, FX.failure, refusal.description)
            case .success(let upload):
                guard let handle = newHandle() else { upload.discard(); return status(id, FX.failure, "Too many open handles") }
                let report = TransferReport(peer: peer, name: target.lastPathComponent, isUpload: true,
                                            total: announced ?? 0, report: access.onProgress)
                let box = OpenHandle(kind: .write(upload, report: report), name: target.lastPathComponent)
                box.total = announced ?? 0
                handles[handle] = box
                return handleReply(id, handle)
            }
        }
        guard let url = SSHServerPath.read(raw, access) else {
            TransferReport.refused(peer: peer, name: display, isUpload: false, detail: "file not found", report: access.onProgress)
            return status(id, FX.noSuchFile, "No such file")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        var st = Darwin.stat()
        guard fd >= 0, Darwin.fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            if fd >= 0 { close(fd) }
            return status(id, FX.noSuchFile, "No such file")
        }
        guard let handle = newHandle() else { close(fd); return status(id, FX.failure, "Too many open handles") }
        let report = TransferReport(peer: peer, name: url.lastPathComponent, isUpload: false,
                                    total: Int64(st.st_size), report: access.onProgress)
        let box = OpenHandle(kind: .read(fd: fd, report: report), name: url.lastPathComponent)
        box.total = Int64(st.st_size)
        handles[handle] = box
        return handleReply(id, handle)
    }

    private func readFile(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let key = try r.readString()
        let offset = try r.readUInt64()
        let length = min(Int(try r.readUInt32()), Self.maximumRead)
        guard let box = handles[key], case .read(let fd, let report) = box.kind else {
            return status(id, FX.failure, "Bad handle")
        }
        guard offset < UInt64(Int64.max) else { return status(id, FX.eof, "End of file") }
        var data = [UInt8](repeating: 0, count: length)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        guard n >= 0 else { return status(id, FX.failure, "read failed") }
        if n == 0 { return status(id, FX.eof, "End of file") }
        box.bytes = max(box.bytes, Int64(offset) + Int64(n))
        report.progress(box.bytes)
        var w = SSHWriter(capacity: n + 16)
        w.writeByte(103)                        // DATA
        w.writeUInt32(id)
        w.writeString(data[0..<n])
        return framed(w.bytes)
    }

    private func writeFile(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        let key = try r.readString()
        let offset = try r.readUInt64()
        let data = try r.readString()
        guard let box = handles[key], case .write(let upload, let report) = box.kind else {
            return status(id, FX.failure, "Bad handle")
        }
        guard offset <= UInt64(Int64.max), upload.write(data[...], at: Int64(offset)) else {
            // Past the size limit (or the disk said no): the upload ends here.
            let detail = Int64(clamping: offset) > upload.limit - Int64(data.count) ? UploadRefusal.tooBig.description : "write failed"
            upload.discard()
            report.failed(detail)
            handles[key] = nil
            return status(id, FX.failure, detail)
        }
        box.bytes = upload.size
        report.progress(box.bytes)
        return status(id, FX.ok, "OK")
    }

    private func closeHandle(_ id: UInt32, _ r: inout SSHReader) throws -> [UInt8] {
        guard let box = handles.removeValue(forKey: try r.readString()) else { return status(id, FX.failure, "Bad handle") }
        switch box.kind {
        case .directory:
            return status(id, FX.ok, "OK")
        case .read(let fd, let report):
            close(fd)
            // A read closed before the end (cancelled, or only the head) is
            // not "sent".
            if box.bytes >= box.total { report.done(box.total) } else { report.failed("stopped at \(box.bytes) bytes") }
            return status(id, FX.ok, "OK")
        case .write(let upload, let report):
            switch upload.commit() {
            case .success:
                report.done(upload.size)
                return status(id, FX.ok, "OK")
            case .failure(let refusal):
                report.failed(refusal.description)
                return status(id, FX.failure, refusal.description)
            }
        }
    }

    // MARK: Wire

    struct Attributes {
        var size: UInt64
        var isDirectory: Bool
        var mtime: UInt32
    }

    static let directoryAttributes = Attributes(size: 0, isDirectory: true, mtime: UInt32(Date().timeIntervalSince1970))

    static func attributes(of url: URL) -> Attributes? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Attributes(size: UInt64(st.st_size), isDirectory: false, mtime: UInt32(clamping: st.st_mtimespec.tv_sec))
    }

    /// The size in OPEN's attrs, when the client sends one.
    static func announcedSize(_ r: inout SSHReader) -> Int64? {
        guard let flags = try? r.readUInt32(), flags & 0x1 != 0, let size = try? r.readUInt64() else { return nil }
        return Int64(clamping: size)
    }

    private func newHandle() -> [UInt8]? {
        guard handles.count < Self.maximumHandles else { return nil }
        nextHandle &+= 1
        var w = SSHWriter()
        w.writeUInt32(nextHandle)
        return w.bytes
    }

    private func status(_ id: UInt32, _ code: UInt32, _ message: String) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(101)
        w.writeUInt32(id)
        w.writeUInt32(code)
        w.writeString(message)
        w.writeString("en")
        return framed(w.bytes)
    }

    private func handleReply(_ id: UInt32, _ handle: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(102)
        w.writeUInt32(id)
        w.writeString(handle)
        return framed(w.bytes)
    }

    private func attrs(_ id: UInt32, _ a: Attributes) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(105)
        w.writeUInt32(id)
        Self.write(a, into: &w)
        return framed(w.bytes)
    }

    private func name(_ id: UInt32, _ entries: [(String, Attributes?)]) -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(104)
        w.writeUInt32(id)
        w.writeUInt32(UInt32(entries.count))
        for (filename, a) in entries {
            w.writeString(filename)
            w.writeString(a.map { Self.longname(filename, $0) } ?? filename)
            if let a { Self.write(a, into: &w) } else { w.writeUInt32(0) }
        }
        return framed(w.bytes)
    }

    private static func write(_ a: Attributes, into w: inout SSHWriter) {
        w.writeUInt32(0x1 | 0x2 | 0x4 | 0x8)    // SIZE | UIDGID | PERMISSIONS | ACMODTIME
        w.writeUInt64(a.size)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(a.isDirectory ? 0o040755 : 0o100644)
        w.writeUInt32(a.mtime)
        w.writeUInt32(a.mtime)
    }

    private static func longname(_ name: String, _ a: Attributes) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm"
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(a.mtime)))
        let perms = a.isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        return "\(perms)    1 sheepterm sheepterm \(String(repeating: " ", count: max(0, 10 - String(a.size).count)))\(a.size) \(date) \(name)"
    }

    private func framed(_ payload: [UInt8]) -> [UInt8] {
        var w = SSHWriter(capacity: payload.count + 4)
        w.writeUInt32(UInt32(payload.count))
        w.writeBytes(payload)
        return w.bytes
    }
}
