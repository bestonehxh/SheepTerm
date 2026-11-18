// An outbound TCP connect that never blocks its caller: the name lookup runs
// on its own thread (getaddrinfo has no timeout of its own; at most
// `maximumLookups` of them at once, app-wide, and `LookupBudget.perOwner` for
// any one session's forwarder), then each
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

    /// Lookups running at once, over every connector. getaddrinfo cannot be
    /// stopped: a dropped connector's thread runs until the resolver gives
    /// up, and a remote SOCKS client (`R1080`) can open and close channels
    /// as fast as it likes — without this every slow name it asked for was
    /// one more thread (review 6.1 (59)). Past the cap a connect fails at
    /// once with `busyMessage` and starts no thread.
    public static let maximumLookups = 64
    public static let busyMessage = "too many name lookups in progress"

    /// One owner's share of the lookups (a session's `PortForwarder`), taken
    /// BEFORE the app-wide cap: a remote SOCKS client on one tab holding 64
    /// slow lookups made every other tab's forward fail at once (6.1 (62)
    /// review). A slot is held until its lookup's thread returns, like the
    /// app-wide one — dropping the connector does not free it.
    public final class LookupBudget: Sendable {
        /// A quarter of the app-wide cap: one session can never take all of
        /// it, and 16 lookups slow at once is far past what a browser behind
        /// a SOCKS forward asks for (names normally answer in milliseconds).
        public static let perOwner = 16
        public let limit: Int
        private let inFlight = Atomic<Int>(0)
        public var running: Int { inFlight.load(ordering: .relaxed) }
        public init(limit: Int = LookupBudget.perOwner) { self.limit = limit }
        fileprivate func take() -> Bool {
            guard inFlight.add(1, ordering: .relaxed).newValue <= limit else {
                inFlight.subtract(1, ordering: .relaxed)
                return false
            }
            return true
        }
        fileprivate func give() { inFlight.subtract(1, ordering: .relaxed) }
    }

    /// Lookups whose thread has not returned, over every connector — a
    /// dropped connector's lookup keeps running until getaddrinfo returns.
    private static let lookupsInFlight = Atomic<Int>(0)
    static var lookupsRunning: Int { lookupsInFlight.load(ordering: .relaxed) }
    /// The lookup itself (tests swap in a slow one).
    nonisolated(unsafe) static var resolve: @Sendable (String, Int) -> Result<[ForwardSocket.Address], ForwardSocket.Failure> = {
        ForwardSocket.resolve(host: $0, port: $1)
    }

    private enum Lookup: Sendable { case waiting, done([ForwardSocket.Address]), failed(String) }
    private final class Box: Sendable { let lookup = Mutex<Lookup>(.waiting) }

    private let box = Box()
    private let deadline: Date
    private var addresses: [ForwardSocket.Address]?
    private var fd: ForwardDescriptor = ForwardSocket.invalid
    private var lastError = "connection refused"
    private var finished = false

    /// `budget` = the owner's share (nil = only the app-wide cap).
    public init(host: String, port: Int, budget: LookupBudget? = nil) {
        deadline = Date().addingTimeInterval(Self.timeout)
        let box = self.box
        let resolve = Self.resolve
        guard budget?.take() ?? true else {
            box.lookup.withLock { $0 = .failed(Self.busyMessage) }
            return
        }
        guard Self.lookupsInFlight.add(1, ordering: .relaxed).newValue <= Self.maximumLookups else {
            Self.lookupsInFlight.subtract(1, ordering: .relaxed)
            budget?.give()
            box.lookup.withLock { $0 = .failed(Self.busyMessage) }
            return
        }
        Thread.detachNewThread {
            let result = resolve(host, port)
            Self.lookupsInFlight.subtract(1, ordering: .relaxed)
            budget?.give()
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
