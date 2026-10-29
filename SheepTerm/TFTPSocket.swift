import Darwin
import Foundation

// The thin I/O under TFTP (`TFTPServer`, `TFTPClient`): plain BSD UDP sockets.
// sendto(2) hands the datagram to the kernel before it returns, and close(2)
// frees the port at once — the two things Network.framework did not give the
// old server (a queued ERROR was dropped by the cancel that followed it, and a
// stopped listener held port 69 for an unknown while).

/// A UDP peer address (IPv4 or IPv6; an IPv4-mapped IPv6 address is
/// compared and shown as the IPv4 it carries).
nonisolated struct UDPAddress: Sendable {
    var storage = sockaddr_storage()
    var length: socklen_t = 0

    init() {}

    init?(_ address: UnsafePointer<sockaddr>, length: socklen_t) {
        guard length > 0, Int(length) <= MemoryLayout<sockaddr_storage>.size else { return nil }
        withUnsafeMutableBytes(of: &storage) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(length)))
        }
        self.length = length
    }

    var family: Int32 { Int32(storage.ss_family) }

    var port: UInt16 {
        get {
            var s = storage
            return withUnsafePointer(to: &s) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        }
        set {
            // sin_port and sin6_port sit at the same offset.
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = newValue.bigEndian }
            }
        }
    }

    func withPort(_ port: UInt16) -> UDPAddress {
        var copy = self
        copy.port = port
        return copy
    }

    /// The host part as raw bytes: 4 for IPv4 (also when IPv4-mapped), 16
    /// for IPv6.
    var hostBytes: [UInt8] {
        var s = storage
        if family == AF_INET {
            return withUnsafePointer(to: &s) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            }
        }
        let bytes: [UInt8] = withUnsafePointer(to: &s) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
        }
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return Array(bytes[12..<16])
        }
        return bytes
    }

    func sameHost(_ other: UDPAddress) -> Bool { hostBytes == other.hostBytes }

    /// "192.168.1.10" / "fe80::1" — the device's address without the port.
    var host: String {
        let bytes = hostBytes
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &text, socklen_t(text.count)) } != nil
        return ok ? String(decoding: text.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) : "?"
    }

    /// Resolves `host` (a name or a literal) for UDP; the first answer.
    static func resolve(_ host: String, port: Int) -> UDPAddress? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        return UDPAddress(info.pointee.ai_addr, length: info.pointee.ai_addrlen)
    }
}

nonisolated enum UDPSocket {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    /// A non-blocking UDP socket of `family` bound to `port` on every
    /// address of that family (0 = any free port). An IPv6 socket is
    /// IPv6-ONLY: macOS lets a dual-stack [::] bind succeed beside another
    /// program's 0.0.0.0 on the same port (two servers on port 69, the
    /// device reaching either), so each family is bound — and refused — on
    /// its own (`listeners`). Never SO_REUSEADDR: a port someone else holds
    /// must fail with EADDRINUSE.
    static func bound(port: UInt16, family: Int32) -> Result<(fd: Int32, family: Int32, port: UInt16), Failure> {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(Failure(code: errno)) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = INADDR_ANY
            result = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard result == 0 else {
            let failure = errno
            close(fd)
            return .failure(Failure(code: failure))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .success((fd, family, localPort(fd)))
    }

    /// The server's listening pair: IPv4 and IPv6 on the same port, or IPv4
    /// alone where this Mac has no IPv6. Either family taken = EADDRINUSE
    /// (nothing stays bound). Port 0 picks a port free in both.
    static func listeners(port: UInt16) -> Result<[(fd: Int32, family: Int32, port: UInt16)], Failure> {
        for _ in 0..<(port == 0 ? 8 : 1) {
            let v4: (fd: Int32, family: Int32, port: UInt16)
            switch bound(port: port, family: AF_INET) {
            case .success(let s): v4 = s
            case .failure(let f): return .failure(f)
            }
            switch bound(port: v4.port, family: AF_INET6) {
            case .success(let v6):
                return .success([v4, v6])
            case .failure(let f) where f.code == EAFNOSUPPORT || f.code == EADDRNOTAVAIL || f.code == EPROTONOSUPPORT:
                return .success([v4])
            case .failure(let f):
                close(v4.fd)
                // An ephemeral IPv4 port that is taken on IPv6: pick again.
                if port == 0 && f.code == EADDRINUSE { continue }
                return .failure(f)
            }
        }
        return .failure(Failure(code: EADDRINUSE))
    }

    static func localPort(_ fd: Int32) -> UInt16 {
        var s = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        } == 0
        guard ok, let address = withUnsafePointer(to: &s, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UDPAddress($0, length: length) }
        }) else { return 0 }
        return address.port
    }

    /// One datagram. A full send buffer or an unreachable host is dropped
    /// like a lost packet: the retransmit timer covers it.
    @discardableResult
    static func send(_ fd: Int32, _ bytes: Data, to address: UDPAddress) -> Bool {
        var target = address
        let length = target.family == AF_INET6 ? socklen_t(MemoryLayout<sockaddr_in6>.size) : socklen_t(MemoryLayout<sockaddr_in>.size)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target.storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, buffer.count, 0, $0, length) }
            }
        }
        return sent == bytes.count
    }

    enum Received {
        case datagram(Data, UDPAddress)
        /// Nothing waiting (non-blocking) or the call was interrupted.
        case empty
        case failed(Int32)
    }

    static func receive(_ fd: Int32, into buffer: inout [UInt8]) -> Received {
        var from = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) }
            }
        }
        if n < 0 {
            let failure = errno
            // ECONNREFUSED & co: an ICMP answer to an earlier send — nothing
            // to read, not the socket's end.
            switch failure {
            case EAGAIN, EINTR, ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN, ECONNRESET: return .empty
            default: return .failed(failure)
            }
        }
        guard let address = withUnsafePointer(to: &from, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UDPAddress($0, length: length) }
        }) else { return .empty }
        return .datagram(Data(buffer[0..<n]), address)
    }

    /// The process's monotonic clock in seconds (what the TFTP machines run on).
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
