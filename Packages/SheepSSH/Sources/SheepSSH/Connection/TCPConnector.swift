// An outbound TCP connect that never blocks its caller: the name lookup runs
// on its own thread (getaddrinfo has no timeout of its own), then each
// address is tried with a non-blocking connect. The owner's loop calls
// `step()` until it answers — remote port forwarding (`ssh -R`) connects to
// the Mac-side target this way, inside the session's I/O loop. The socket
// calls are ForwardSocket's (POSIX, or WinSock in the Windows port).
import Foundation
import Synchronization

public final class TCPConnector {
    public enum Step: Equatable { case pending, connected(ForwardDescriptor), failed(String) }

    /// The whole budget: lookup and every address.
    public static let timeout: TimeInterval = 15

    private enum Lookup: Sendable { case waiting, done([ForwardSocket.Address]), failed(String) }
    private final class Box: Sendable { let lookup = Mutex<Lookup>(.waiting) }

    private let box = Box()
    private let deadline: Date
    private var addresses: [ForwardSocket.Address]?
    private var fd: ForwardDescriptor = ForwardSocket.invalid
    private var lastError = "connection refused"
    private var finished = false

    public init(host: String, port: Int) {
        deadline = Date().addingTimeInterval(Self.timeout)
        let box = self.box
        Thread.detachNewThread {
            let result = ForwardSocket.resolve(host: host, port: port)
            box.lookup.withLock {
                switch result {
                case .success(let found): $0 = .done(found)
                case .failure(let why): $0 = .failed(why.message)
                }
            }
        }
    }

    deinit { if fd != ForwardSocket.invalid { ForwardSocket.close(fd) } }

    /// Never blocks. Once it answers `.connected`, the descriptor is the
    /// caller's (non-blocking, not inherited); `.failed` is final too.
    public func step() -> Step {
        guard !finished else { return .failed(lastError) }
        if Date() > deadline { return fail("timed out") }
        if addresses == nil {
            switch box.lookup.withLock({ $0 }) {
            case .waiting: return .pending
            case .failed(let why): return fail(why)
            case .done(let list): addresses = list
            }
        }
        while true {
            if fd == ForwardSocket.invalid {
                guard var list = addresses, !list.isEmpty else { return fail(lastError) }
                let next = list.removeFirst()
                addresses = list
                switch ForwardSocket.startConnect(next) {
                case .connected(let s): return done(s)
                case .failed(let why): lastError = why; continue
                case .inProgress(let s): fd = s
                }
            }
            switch ForwardSocket.connectResult(fd) {
            case .pending:
                return .pending
            case .connected:
                let s = fd
                fd = ForwardSocket.invalid
                return done(s)
            case .failed(let why):
                lastError = why
                ForwardSocket.close(fd)
                fd = ForwardSocket.invalid
            }
        }
    }

    private func done(_ s: ForwardDescriptor) -> Step {
        finished = true
        return .connected(s)
    }

    private func fail(_ why: String) -> Step {
        finished = true
        lastError = why
        if fd != ForwardSocket.invalid { ForwardSocket.close(fd); fd = ForwardSocket.invalid }
        return .failed(why)
    }
}
