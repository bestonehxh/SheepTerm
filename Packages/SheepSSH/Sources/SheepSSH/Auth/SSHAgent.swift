// ssh-agent client (draft-miller-ssh-agent): list identities and ask for
// signatures over the agent's Unix socket. Each request opens its own short
// connection, so a signer can be used from whatever queue drives userauth.
// Blocking, with a timeout — the agent is local, and a hung agent must not
// hang the connection attempt.
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum SSHAgent {
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let failure: UInt8 = 5
    static let flagRSASHA256: UInt32 = 2
    static let flagRSASHA512: UInt32 = 4

    /// Replies larger than this are refused (a real one is a few KiB).
    static let maximumReply = 256 * 1024

    /// `SSH_AUTH_SOCK`, if set and non-empty.
    public static var socketPath: String? {
        guard let p = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !p.isEmpty else { return nil }
        return p
    }

    public final class Identity: SSHSigner {
        public let publicKey: SSHPublicKey
        public let comment: String
        let socketPath: String
        let timeout: TimeInterval
        /// Checked while a signature is awaited (it may wait a minute for
        /// the user's approval): true ends the wait, e.g. the tab closed.
        public var shouldCancel: (@Sendable () -> Bool)?
        public var label: String { "agent: \(comment.isEmpty ? publicKey.fingerprintSHA256 : comment)" }

        init(publicKey: SSHPublicKey, comment: String, socketPath: String, timeout: TimeInterval) {
            self.publicKey = publicKey
            self.comment = comment
            self.socketPath = socketPath
            self.timeout = timeout
        }

        public func sign(_ data: [UInt8], algorithm: String) throws(SignerError) -> [UInt8] {
            var flags: UInt32 = 0
            if algorithm == "rsa-sha2-256" { flags = SSHAgent.flagRSASHA256 }
            if algorithm == "rsa-sha2-512" { flags = SSHAgent.flagRSASHA512 }
            var w = SSHWriter()
            w.writeByte(SSHAgent.signRequest)
            w.writeString(publicKey.blob)
            w.writeString(data)
            w.writeUInt32(flags)
            let reply = try SSHAgent.roundTrip(w.bytes, socketPath: socketPath, timeout: timeout, cancel: shouldCancel)
            var r = SSHReader(reply)
            do {
                let type = try r.readByte()
                guard type == SSHAgent.signResponse else {
                    throw SignerError.agent(type == SSHAgent.failure ? "the agent refused to sign" : "unexpected agent reply \(type)")
                }
                let blob = try r.readString()
                // The agent must have signed with the algorithm we asked for:
                // an old agent answering an rsa-sha2 request with ssh-rsa
                // would otherwise be sent to the server as a mismatch.
                var check = SSHReader(blob)
                let name = try check.readUTF8()
                guard name == algorithm else { throw SignerError.agent("agent signed with \(name), not \(algorithm)") }
                return blob
            } catch let error as SignerError {
                throw error
            } catch {
                throw .agent("malformed agent reply")
            }
        }
    }

    /// The agent's keys, in the agent's order. Keys of types SheepSSH cannot
    /// use (certificates, FIDO) are skipped.
    /// `timeout` bounds the listing; `signTimeout` each later signature,
    /// longer on purpose: 1Password, Secretive (Touch ID) and `ssh-add -c`
    /// wait for the user to approve, and 5 s dropped a key the server had
    /// already accepted.
    public static func identities(socketPath: String, timeout: TimeInterval = 5,
                                  signTimeout: TimeInterval = 60) throws(SignerError) -> [Identity] {
        let reply = try roundTrip([requestIdentities], socketPath: socketPath, timeout: timeout)
        var r = SSHReader(reply)
        do {
            let type = try r.readByte()
            guard type == identitiesAnswer else { throw SignerError.agent("unexpected agent reply \(type)") }
            let count = try r.readUInt32()
            var result: [Identity] = []
            for _ in 0..<min(count, 1024) {
                let blob = try r.readString()
                let comment = String(decoding: try r.readString(), as: UTF8.self)
                if let key = try? SSHPublicKey(blob: blob) {
                    result.append(Identity(publicKey: key, comment: comment, socketPath: socketPath, timeout: signTimeout))
                }
            }
            return result
        } catch let error as SignerError {
            throw error
        } catch {
            throw .agent("malformed identities answer")
        }
    }

    /// One request/response on a fresh connection.
    /// One deadline for the whole exchange (not a fresh `timeout` per
    /// read), and `cancel`, checked every 200 ms, ends it early.
    static func roundTrip(_ message: [UInt8], socketPath: String, timeout: TimeInterval,
                          cancel: (@Sendable () -> Bool)? = nil) throws(SignerError) -> [UInt8] {
        let fd = try connect(socketPath)
        defer { _ = close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        var frame = SSHWriter()
        frame.writeString(message)
        try writeAll(fd, frame.bytes, deadline: deadline, cancel: cancel)
        let header = try readExactly(fd, 4, deadline: deadline, cancel: cancel)
        let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard length >= 1, length <= maximumReply else { throw .agent("agent reply of \(length) bytes") }
        return try readExactly(fd, length, deadline: deadline, cancel: cancel)
    }

    static func connect(_ path: String) throws(SignerError) -> Int32 {
#if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
#endif
        guard fd >= 0 else { throw .agent("socket() failed") }
        // Not inherited across exec (a local shell tab's child would keep
        // the agent connection alive after we close it).
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
#if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // A write to an agent that just died must be an error, not SIGPIPE.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
#endif
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { _ = close(fd); throw .agent("SSH_AUTH_SOCK path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sheepConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            _ = close(fd)
            throw .agent("cannot reach ssh-agent at \(path)")
        }
        return fd
    }

    static func wait(_ fd: Int32, events: Int16, deadline: Date, cancel: (@Sendable () -> Bool)?) throws(SignerError) {
        var p = pollfd(fd: fd, events: events, revents: 0)
        while true {
            if cancel?() == true { throw .agent("cancelled") }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw .agent("ssh-agent did not answer in time") }
            // Short slices, so a cancel is seen; EINTR just goes round again.
            let rc = poll(&p, 1, Int32(min(left, 0.2) * 1000) + 1)
            if rc > 0 { return }
            if rc < 0, errno != EINTR { throw .agent("poll failed") }
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: Date, cancel: (@Sendable () -> Bool)?) throws(SignerError) {
        var sent = 0
        while sent < bytes.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancel: cancel)
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, sendFlags) }
            guard n > 0 else { throw .agent("write to ssh-agent failed") }
            sent += n
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int, deadline: Date, cancel: (@Sendable () -> Bool)?) throws(SignerError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, cancel: cancel)
            let n = out[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw .agent("ssh-agent closed the connection") }
            got += n
        }
        return out
    }
}

#if canImport(Glibc)
private let sheepConnect = Glibc.connect
private let sendFlags = Int32(MSG_NOSIGNAL)
#else
private let sheepConnect = Darwin.connect
private let sendFlags: Int32 = 0
#endif
