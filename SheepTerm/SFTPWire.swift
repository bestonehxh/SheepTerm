import Foundation
import SheepSSH

// SFTP v3 (draft-ietf-secsh-filexfer-02), wire level and sans-I/O — ported
// from SheepDrop's SFTPProtocolClient (proven against real switches).
// Builders return framed packets the owner writes to the "sftp" subsystem
// channel; `consume` reassembles length-framed replies from the channel's
// data. Many requests may be in flight (transfers pipeline): every reply is
// matched to its request id, and a late reply to a request the owner gave up
// on (`forget`) is dropped instead of being handed to the next caller.
//
// Queue-confined to the owning SFTPClient engine.

nonisolated struct SFTPWireError: Error, Sendable {
    let message: String
    /// The device's command shell answered instead of an SFTP server
    /// (Check Point clish: "CLINFR0…"): its first line, for the error.
    var shellText: String? = nil
}

nonisolated final class SFTPWire {
    /// SSH_FX_* status codes. 11 (FILE_ALREADY_EXISTS) is v5+, but some
    /// servers send it on v3 anyway.
    enum Status {
        static let ok: UInt32 = 0
        static let eof: UInt32 = 1
        static let noSuchFile: UInt32 = 2
        static let permissionDenied: UInt32 = 3
        static let failure: UInt32 = 4
        static let opUnsupported: UInt32 = 8
        static let fileAlreadyExists: UInt32 = 11
    }

    struct NameEntry: Equatable {
        var name: String
        var attrs: Attrs
    }

    /// The v3 ATTRS block, reduced to what a listing needs.
    struct Attrs: Equatable {
        var size: UInt64?
        var permissions: UInt32?
        var mtime: UInt32?

        static func read(_ r: inout SSHReader) throws(SSHWireError) -> Attrs {
            var attrs = Attrs()
            let flags = try r.readUInt32()
            if flags & 0x1 != 0 { attrs.size = try r.readUInt64() }          // SIZE
            if flags & 0x2 != 0 { _ = try r.readUInt32(); _ = try r.readUInt32() }  // UIDGID
            if flags & 0x4 != 0 { attrs.permissions = try r.readUInt32() }   // PERMISSIONS
            if flags & 0x8 != 0 { _ = try r.readUInt32(); attrs.mtime = try r.readUInt32() }  // ACMODTIME
            if flags & 0x80000000 != 0 {                                     // EXTENDED
                let count = try r.readUInt32()
                for _ in 0..<count { _ = try r.readString(); _ = try r.readString() }
            }
            return attrs
        }

        /// S_IFDIR in the permission bits. v3 has no type field — servers
        /// (network gear especially) only set the mode.
        var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
        var isSymlink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
    }

    enum Reply: Equatable {
        case version(UInt32)
        case handle([UInt8])
        case data([UInt8])
        case status(code: UInt32, message: String)
        case names([NameEntry])
        case attrs(Attrs)
    }

    private var inbox: [UInt8] = []
    private var inboxStart = 0
    private var replies: [UInt32: Reply] = [:]
    /// Arrival order of `replies` keys (for `takeAnyReply`).
    private var order: [UInt32] = []
    private var lastRequestID: UInt32 = 0
    /// Requests sent and not yet answered.
    private var outstanding: Set<UInt32> = []
    private(set) var serverVersion: UInt32 = 0
    /// The id of the request built last (the owner just sent it).
    var latestRequestID: UInt32 { lastRequestID }
    var outstandingCount: Int { outstanding.count }

    // MARK: Outgoing

    func initPacket() -> [UInt8] {
        var w = SSHWriter()
        w.writeByte(1)                          // SSH_FXP_INIT
        w.writeUInt32(3)
        return framed(w.bytes)
    }

    private func framed(_ payload: [UInt8]) -> [UInt8] {
        var out = SSHWriter(capacity: payload.count + 4)
        out.writeUInt32(UInt32(payload.count))
        out.writeBytes(payload)
        return out.bytes
    }

    private func request(_ type: UInt8, _ body: (inout SSHWriter) -> Void) -> [UInt8] {
        lastRequestID &+= 1
        if lastRequestID == 0 { lastRequestID = 1 }
        outstanding.insert(lastRequestID)
        var w = SSHWriter()
        w.writeByte(type)
        w.writeUInt32(lastRequestID)
        body(&w)
        return framed(w.bytes)
    }

    func realpath(_ path: String) -> [UInt8] { request(16) { $0.writeString(path) } }
    func stat(_ path: String) -> [UInt8] { request(17) { $0.writeString(path) } }
    func lstat(_ path: String) -> [UInt8] { request(7) { $0.writeString(path) } }

    func openRead(_ path: String) -> [UInt8] {
        request(3) { w in
            w.writeString(path)
            w.writeUInt32(0x1)                  // READ
            w.writeUInt32(0)                    // no attrs
        }
    }

    func openWrite(_ path: String) -> [UInt8] {
        request(3) { w in
            w.writeString(path)
            w.writeUInt32(0x2 | 0x8 | 0x10)     // WRITE | CREAT | TRUNC
            w.writeUInt32(0x4)                  // attrs: permissions
            w.writeUInt32(0o644)
        }
    }

    func read(handle: [UInt8], offset: UInt64, length: Int) -> [UInt8] {
        request(5) { w in
            w.writeString(handle)
            w.writeUInt64(offset)
            w.writeUInt32(UInt32(length))
        }
    }

    func write(handle: [UInt8], offset: UInt64, _ data: ArraySlice<UInt8>) -> [UInt8] {
        request(6) { w in
            w.writeString(handle)
            w.writeUInt64(offset)
            w.writeString(data)
        }
    }

    func close(_ handle: [UInt8]) -> [UInt8] { request(4) { $0.writeString(handle) } }
    func openDir(_ path: String) -> [UInt8] { request(11) { $0.writeString(path) } }
    func readDir(_ handle: [UInt8]) -> [UInt8] { request(12) { $0.writeString(handle) } }
    func remove(_ path: String) -> [UInt8] { request(13) { $0.writeString(path) } }
    func rmdir(_ path: String) -> [UInt8] { request(15) { $0.writeString(path) } }

    func mkdir(_ path: String) -> [UInt8] {
        request(14) { w in
            w.writeString(path)
            w.writeUInt32(0x4)
            w.writeUInt32(0o755)
        }
    }

    func rename(_ from: String, _ to: String) -> [UInt8] {
        request(18) { w in
            w.writeString(from)
            w.writeString(to)
        }
    }

    // MARK: Incoming

    /// Feeds channel data; parses every complete reply. A malformed stream
    /// throws (the session cannot be trusted after that).
    func consume(_ bytes: [UInt8]) throws(SFTPWireError) {
        inbox.append(contentsOf: bytes)
        do {
            while try parseOne() {}
        } catch {
            inbox.removeAll()
            inboxStart = 0
            throw error
        }
        // Compact once the parsed prefix is large (a 32 KB DATA at a time).
        if inboxStart > 256 * 1024 || inboxStart == inbox.count {
            inbox.removeFirst(inboxStart)
            inboxStart = 0
        }
    }

    func takeReply(for id: UInt32) -> Reply? {
        guard let reply = replies.removeValue(forKey: id) else { return nil }
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        return reply
    }

    /// The oldest reply that arrived, with the id it answers.
    func takeAnyReply() -> (id: UInt32, reply: Reply)? {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let reply = replies.removeValue(forKey: id) { return (id, reply) }
        }
        return nil
    }

    /// Gives up on a request: its late reply is dropped.
    func forget(_ id: UInt32) {
        outstanding.remove(id)
        _ = takeReply(for: id)
    }

    /// The first line of `bytes` when they open with 4 printable ASCII
    /// characters (no SFTP length is that large and all-text), else nil.
    static func shellLine(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count >= 4, bytes.prefix(4).allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        let line = bytes.prefix { $0 != 0x0A && $0 != 0x0D }.prefix(120)
        let text = String(decoding: line.map { (0x20...0x7E).contains($0) ? $0 : 0x3F }, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func parseOne() throws(SFTPWireError) -> Bool {
        let available = inbox.count - inboxStart
        guard available >= 4 else { return false }
        let s = inboxStart
        let length = Int(inbox[s]) << 24 | Int(inbox[s + 1]) << 16 | Int(inbox[s + 2]) << 8 | Int(inbox[s + 3])
        // Text where the first packet's length should be: a login shell
        // (not an SFTP server) runs the subsystem — say what it printed.
        if serverVersion == 0, let text = Self.shellLine(inbox[s...]) {
            throw SFTPWireError(message: "the device's shell answered, not SFTP", shellText: text)
        }
        // A hostile length must not grow the buffer without bound.
        guard length >= 1, length <= 4 << 20 else {
            throw SFTPWireError(message: "SFTP reply length \(length) out of range")
        }
        guard available >= 4 + length else { return false }
        let payload = Array(inbox[(s + 4)..<(s + 4 + length)])
        inboxStart += 4 + length

        let type = payload[0]
        var r = SSHReader(payload, from: 1)
        do {
            if type == 2 {                                  // VERSION
                serverVersion = try r.readUInt32()
                return true
            }
            let id = try r.readUInt32()
            // Only a reply to a request still awaited belongs to anyone.
            guard outstanding.remove(id) != nil else { return true }
            let reply: Reply
            switch type {
            case 102: reply = .handle(try r.readString())
            case 103: reply = .data(try r.readString())
            case 101:
                let code = try r.readUInt32()
                let message = (try? r.readUTF8()) ?? ""
                reply = .status(code: code, message: message)
            case 104:
                let count = Int(try r.readUInt32())
                guard count <= length / 9 else { throw SSHWireError.truncated }
                var entries: [NameEntry] = []
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    let name = String(decoding: try r.readString(), as: UTF8.self)
                    _ = try r.readString()                  // longname
                    entries.append(NameEntry(name: name, attrs: try Attrs.read(&r)))
                }
                reply = .names(entries)
            case 105: reply = .attrs(try Attrs.read(&r))
            default:
                throw SFTPWireError(message: "unexpected SFTP reply type \(type)")
            }
            replies[id] = reply
            order.append(id)
            return true
        } catch let error as SFTPWireError {
            throw error
        } catch {
            throw SFTPWireError(message: "malformed SFTP reply type \(type)")
        }
    }

    /// 0o755 → "rwxr-xr-x".
    static func permissionString(_ mode: UInt32?) -> String? {
        guard let mode else { return nil }
        let bits: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                           (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                           (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return String(bits.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }
}
