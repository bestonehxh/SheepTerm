// The few socket calls port forwarding makes (PortForwarder, TCPConnector),
// one spelling per platform: POSIX sockets on the Mac (and Linux, for the
// test containers), WinSock on Windows (the SheepTerm Windows port). Every
// socket here is non-blocking, and never inherited by a child process
// (FD_CLOEXEC / WSA_FLAG_NO_HANDLE_INHERIT): a shell started from the app
// must not keep a tunnel's socket open after the session closed it.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

#if os(Windows)
/// A socket as the owner's poll set takes it (`WSAPOLLFD.fd` on Windows).
public typealias ForwardDescriptor = SOCKET
#else
/// A socket as the owner's poll set takes it (`pollfd.fd`).
public typealias ForwardDescriptor = Int32
#endif

enum ForwardSocket {
    enum IO: Equatable { case bytes(Int), wouldBlock, eof, failed }
    enum ConnectStart: Equatable { case connected(ForwardDescriptor), inProgress(ForwardDescriptor), failed(String) }
    enum ConnectPoll: Equatable { case pending, connected, failed(String) }
    struct Address: Sendable { let family: Int32; let bytes: [UInt8] }
    /// A lookup that found nothing, in the words the notice uses.
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Why a listener could not be opened, in the words the notice uses.
    struct ListenFailure: Error, CustomStringConvertible {
        let code: Int32
        let description: String
    }

    #if os(Windows)
    static let invalid: ForwardDescriptor = INVALID_SOCKET
    private static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    private static let noInherit = DWORD(0x80)          // WSA_FLAG_NO_HANDLE_INHERIT
    private static let pollOut: Int16 = 0x0010          // POLLWRNORM

    static func listenLoopback(port: Int) -> Result<ForwardDescriptor, ListenFailure> {
        guard started else { return .failure(ListenFailure(code: -1, description: "WinSock could not be started")) }
        guard (1...65535).contains(port) else { return .failure(listenFailure(WSAEINVAL)) }
        let s = WSASocketW(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue), nil, 0, noInherit)
        guard s != INVALID_SOCKET else { return .failure(listenFailure(WSAGetLastError())) }
        // No SO_REUSEADDR: on Windows it lets ANOTHER socket take a port that is
        // already bound. The default already rebinds a port whose old
        // connections linger (TIME_WAIT is per connection here).
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 64) == 0 else {
            let code = WSAGetLastError()
            _ = closesocket(s)
            return .failure(listenFailure(code))
        }
        setNonBlocking(s)
        return .success(s)
    }

    private static func listenFailure(_ code: Int32) -> ListenFailure {
        switch code {
        case WSAEADDRINUSE: return ListenFailure(code: code, description: "port in use on this PC")
        case WSAEACCES: return ListenFailure(code: code, description: "port in use or reserved on this PC")
        default: return ListenFailure(code: code, description: message(code))
        }
    }

    static func accept(_ listener: ForwardDescriptor) -> (ForwardDescriptor, originPort: Int)? {
        var address = sockaddr_storage()
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        let s = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { WinSDK.accept(listener, $0, &length) }
        }
        guard s != INVALID_SOCKET else { return nil }
        return (s, port(of: address))
    }

    static func configure(_ s: ForwardDescriptor) {
        setNonBlocking(s)
        // HANDLE_FLAG_INHERIT off: a child process must not keep the tunnel open
        if let handle = HANDLE(bitPattern: UInt(s)) { _ = SetHandleInformation(handle, 0x1, 0) }
        setInt(s, level: Int32(IPPROTO_TCP.rawValue), name: 0x0001, 1)       // TCP_NODELAY
    }

    static func read(_ s: ForwardDescriptor, into buffer: UnsafeMutableRawBufferPointer) -> IO {
        let n = recv(s, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(min(buffer.count, Int(Int32.max))), 0)
        if n > 0 { return .bytes(Int(n)) }
        if n == 0 { return .eof }
        let e = WSAGetLastError()
        return e == WSAEWOULDBLOCK || e == WSAEINTR ? .wouldBlock : .failed
    }

    static func write(_ s: ForwardDescriptor, _ buffer: UnsafeRawBufferPointer) -> IO {
        let n = send(s, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(min(buffer.count, 1 << 20)), 0)
        if n > 0 { return .bytes(Int(n)) }
        let e = WSAGetLastError()
        return n < 0 && (e == WSAEWOULDBLOCK || e == WSAEINTR) ? .wouldBlock : .failed
    }

    static func shutdownWrite(_ s: ForwardDescriptor) { _ = shutdown(s, 1) }      // SD_SEND
    static func close(_ s: ForwardDescriptor) { _ = closesocket(s) }

    static func resolve(host: String, port: Int) -> Result<[Address], Failure> {
        guard started else { return .failure(Failure("WinSock could not be started")) }
        var hints = ADDRINFOA()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP.rawValue)
        var list: UnsafeMutablePointer<ADDRINFOA>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else { return .failure(Failure("cannot resolve \(host) (error \(rc))")) }
        var found: [Address] = []
        var cursor: UnsafeMutablePointer<ADDRINFOA>? = first
        while let info = cursor {
            if let sa = info.pointee.ai_addr {
                found.append(Address(family: info.pointee.ai_family,
                                     bytes: Array(UnsafeRawBufferPointer(start: sa, count: Int(info.pointee.ai_addrlen)))))
            }
            cursor = info.pointee.ai_next
        }
        freeaddrinfo(first)
        return found.isEmpty ? .failure(Failure("cannot resolve \(host)")) : .success(found)
    }

    static func startConnect(_ address: Address) -> ConnectStart {
        let s = WSASocketW(address.family, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue), nil, 0, noInherit)
        guard s != INVALID_SOCKET else { return .failed(message(WSAGetLastError())) }
        setNonBlocking(s)
        let rc = address.bytes.withUnsafeBytes {
            WinSDK.connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32(address.bytes.count))
        }
        if rc == 0 { return .connected(s) }
        let e = WSAGetLastError()
        guard e == WSAEWOULDBLOCK else {
            _ = closesocket(s)
            return .failed(message(e))
        }
        return .inProgress(s)
    }

    static func connectResult(_ s: ForwardDescriptor) -> ConnectPoll {
        var p = WSAPOLLFD(fd: s, events: pollOut, revents: 0)
        guard withUnsafeMutablePointer(to: &p, { WSAPoll($0, 1, 0) }) > 0 else { return .pending }
        var error: Int32 = 0
        var length = Int32(MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &error) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(s, Int32(SOL_SOCKET), Int32(SO_ERROR), $0, &length) }
        }
        if error == 0, p.revents & pollOut != 0 { return .connected }
        return .failed(message(error != 0 ? error : WSAECONNREFUSED))
    }

    private static func setNonBlocking(_ s: ForwardDescriptor) {
        var one: UInt32 = 1
        _ = ioctlsocket(s, FIONBIO, &one)
    }

    private static func setInt(_ s: ForwardDescriptor, level: Int32, name: Int32, _ value: Int32) {
        var v = value
        _ = withUnsafePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(s, level, name, $0, 4) }
        }
    }

    static func message(_ code: Int32) -> String {
        switch code {
        case WSAECONNREFUSED: return "Connection refused"
        case WSAETIMEDOUT: return "Operation timed out"
        case WSAENETUNREACH: return "Network is unreachable"
        case WSAEHOSTUNREACH: return "No route to host"
        case WSAECONNRESET: return "Connection reset by peer"
        case WSAEADDRINUSE: return "Address already in use"
        case WSAEACCES: return "Permission denied"
        default: return "WinSock error \(code)"
        }
    }
    #else
    static let invalid: ForwardDescriptor = -1

    static func listenLoopback(port: Int) -> Result<ForwardDescriptor, ListenFailure> {
        guard (1...65535).contains(port) else { return .failure(listenFailure(EINVAL)) }
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { return .failure(listenFailure(errno)) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listenFD(fd, 64) == 0 else {
            let code = errno
            close(fd)
            return .failure(listenFailure(code))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return .success(fd)
    }

    private static func listenFailure(_ code: Int32) -> ListenFailure {
        switch code {
        case EADDRINUSE: return ListenFailure(code: code, description: "port in use on this Mac")
        case EACCES: return ListenFailure(code: code, description: "ports below 1024 need administrator rights")
        default: return ListenFailure(code: code, description: String(cString: strerror(code)))
        }
    }

    static func accept(_ listener: ForwardDescriptor) -> (ForwardDescriptor, originPort: Int)? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let fd = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { acceptFD(listener, $0, &length) }
        }
        guard fd >= 0 else { return nil }
        return (fd, port(of: address))
    }

    static func configure(_ fd: ForwardDescriptor) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        #if canImport(Darwin)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func read(_ fd: ForwardDescriptor, into buffer: UnsafeMutableRawBufferPointer) -> IO {
        let n = readFD(fd, buffer.baseAddress, buffer.count)
        if n > 0 { return .bytes(n) }
        if n == 0 { return .eof }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? .wouldBlock : .failed
    }

    static func write(_ fd: ForwardDescriptor, _ buffer: UnsafeRawBufferPointer) -> IO {
        let n = send(fd, buffer.baseAddress, buffer.count, sendFlags)
        if n > 0 { return .bytes(n) }
        return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? .wouldBlock : .failed
    }

    static func shutdownWrite(_ fd: ForwardDescriptor) { _ = shutdown(fd, Int32(SHUT_WR)) }
    static func close(_ fd: ForwardDescriptor) { _ = closeFD(fd) }

    static func resolve(host: String, port: Int) -> Result<[Address], Failure> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStream
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else { return .failure(Failure("cannot resolve \(host): \(String(cString: gai_strerror(rc)))")) }
        var found: [Address] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sa = info.pointee.ai_addr {
                found.append(Address(family: info.pointee.ai_family,
                                     bytes: Array(UnsafeRawBufferPointer(start: sa, count: Int(info.pointee.ai_addrlen)))))
            }
            cursor = info.pointee.ai_next
        }
        freeaddrinfo(first)
        return found.isEmpty ? .failure(Failure("cannot resolve \(host)")) : .success(found)
    }

    static func startConnect(_ address: Address) -> ConnectStart {
        let s = socket(address.family, sockStream, 0)
        guard s >= 0 else { return .failed(String(cString: strerror(errno))) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        let rc = address.bytes.withUnsafeBytes {
            connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.bytes.count))
        }
        if rc == 0 { return .connected(s) }
        guard errno == EINPROGRESS else {
            let why = String(cString: strerror(errno))
            _ = closeFD(s)
            return .failed(why)
        }
        return .inProgress(s)
    }

    static func connectResult(_ fd: ForwardDescriptor) -> ConnectPoll {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return .pending }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0 ? .connected : .failed(String(cString: strerror(error)))
    }

    #if canImport(Darwin)
    private static let sockStream = SOCK_STREAM
    private static let sendFlags: Int32 = 0
    private static func closeFD(_ fd: Int32) -> Int32 { Darwin.close(fd) }
    private static func readFD(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Darwin.read(fd, p, n) }
    private static func acceptFD(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 { Darwin.accept(fd, address, length) }
    private static func listenFD(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    #else
    private static let sockStream = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    private static func closeFD(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    private static func readFD(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Glibc.read(fd, p, n) }
    private static func acceptFD(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 { Glibc.accept(fd, address, length) }
    private static func listenFD(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    #endif
    #endif

    /// The peer's port of an accepted IPv4 connection.
    private static func port(of address: sockaddr_storage) -> Int {
        var copy = address
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
    }
}
