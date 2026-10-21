import Foundation
#if canImport(Network)
import Network

/// The other end of Google's redirect for an installed app: a one-shot HTTP
/// listener on 127.0.0.1 (never on an outside interface), on a port the
/// system picks. The browser is sent to Google; Google sends it back to
/// `http://127.0.0.1:<port>/?code=…&state=…`; this answers with a short
/// "you can close this tab" page and hands the parameters over.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SheepSync.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// An answer that arrived before anyone waited for it.
    private var early: Result<[String: String], Error>?
    private var done = false
    private let appName: String
    /// Only an answer carrying this `state` ends the wait: any local process
    /// can reach the port, and a stray "?error=x" must not abort sign-in.
    private var expectedState = ""

    /// The redirect URI to give Google; valid once `start` returned.
    private(set) var redirectURI = ""

    init(appName: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        self.appName = appName
    }

    /// Starts listening and returns the redirect URI.
    func start(expectedState: String) async throws -> String {
        queue.sync { self.expectedState = expectedState }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { ready.resume() }
                case .failed(let error): if once.claim() { ready.resume(throwing: error) }
                // Cancelled before it was ever ready (sign-in cancelled at
                // once): without this the caller waited forever.
                case .cancelled: if once.claim() { ready.resume(throwing: GoogleOAuth.OAuthError.cancelled) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            // On the queue `finish` runs on: a cancel that already happened
            // is seen here (a cancelled, never-started listener reports no
            // state at all, so waiting for one would hang).
            queue.async {
                if self.done {
                    if once.claim() { ready.resume(throwing: GoogleOAuth.OAuthError.cancelled) }
                } else {
                    self.listener.start(queue: self.queue)
                }
            }
        }
        guard let port = listener.port?.rawValue else { throw GoogleOAuth.OAuthError.server("no loopback port") }
        redirectURI = "http://127.0.0.1:\(port)"
        return redirectURI
    }

    /// Waits for the redirect carrying a code or an error. A request without
    /// either (the browser asking for /favicon.ico) is answered and ignored.
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.early {
                    self.early = nil
                    continuation.resume(with: early)
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(GoogleOAuth.OAuthError.timedOut))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(GoogleOAuth.OAuthError.cancelled)) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !done else { return }
        done = true
        listener.cancel()
        guard let continuation else { early = result; return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, into: Data())
    }

    /// Reads until the request line is complete (it can arrive in pieces),
    /// at most 16 KB.
    private func read(_ connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let hasLine = buffer.range(of: Data("\r\n".utf8)) != nil || buffer.range(of: Data("\n".utf8)) != nil
            if !hasLine, !isComplete, error == nil, buffer.count < 16 * 1024 {
                self.read(connection, into: buffer)
                return
            }
            self.respond(connection, head: String(decoding: buffer, as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        do {
            let firstLine = head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let parameters = GoogleOAuth.redirectParameters(requestLine: firstLine)
            let isAnswer = parameters.map {
                ($0["code"] != nil || $0["error"] != nil) && $0["state"] == self.expectedState
            } ?? false
            let body = isAnswer ? Self.page(appName: self.appName, ok: parameters?["code"] != nil) : ""
            let status = isAnswer ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isAnswer, let parameters { self.finish(.success(parameters)) }
        }
    }

    static func page(appName: String, ok: Bool) -> String {
        let title = ok ? "Signed in" : "Sign-in not completed"
        let text = ok ? "You can close this tab and go back to \(appName)."
                      : "Go back to \(appName) and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>\(appName)</title>
            <style>body{font:15px -apple-system,sans-serif;background:#1e1e1e;color:#eee;\
            display:flex;align-items:center;justify-content:center;height:90vh}</style></head>
            <body><div><h2>\(title)</h2><p>\(text)</p></div></body></html>
            """
    }
}
#endif

#if !canImport(Network)
#if os(Windows)
import WinSDK

/// The same one-shot loopback listener without Network.framework (Windows):
/// a WinSock socket bound to 127.0.0.1 on a port the system picks, served by
/// one background thread that polls with a short timeout so `cancel` and the
/// 5-minute limit are honoured. Same contract as the Apple version above.
final class LoopbackReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var early: Result<[String: String], Error>?
    private var done = false
    private var expectedState = ""
    private let appName: String
    private var listener: SOCKET = INVALID_SOCKET
    private var deadline = Date.distantFuture
    private(set) var redirectURI = ""

    init(appName: String) throws {
        self.appName = appName
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { throw GoogleOAuth.OAuthError.server("WinSock could not be started") }
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func start(expectedState: String) async throws -> String {
        locked { self.expectedState = expectedState }
        let s = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
        guard s != INVALID_SOCKET else { throw GoogleOAuth.OAuthError.server("no loopback socket") }
        var addr = sockaddr_in()
        addr.sin_family = UInt16(AF_INET)
        addr.sin_addr.S_un.S_addr = UInt32(0x0100007F)   // 127.0.0.1
        addr.sin_port = 0
        let size = Int32(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, size) } }
        var len = size
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        guard bound == 0, named == 0, listen(s, 4) == 0 else {
            _ = closesocket(s)
            throw GoogleOAuth.OAuthError.server("no loopback port")
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let wasCancelled: Bool = locked { if done { return true }; listener = s; return false }
        if wasCancelled { _ = closesocket(s); throw GoogleOAuth.OAuthError.cancelled }
        Thread.detachNewThread { [self] in serveLoop(s) }
        redirectURI = "http://127.0.0.1:\(port)"
        return redirectURI
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[String: String], Error>? = locked {
                if let early { self.early = nil; return early }
                self.continuation = continuation
                deadline = Date().addingTimeInterval(timeout)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func cancel() { finish(.failure(GoogleOAuth.OAuthError.cancelled)) }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>?? = locked {
            guard !done else { return .none }
            done = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { early = result }
            return .some(waiting)
        }
        if case .some(.some(let waiting)) = waiting { waiting.resume(with: result) }   // the serve loop notices `done` and closes the socket
    }

    private var isDone: Bool { locked { done } }
    private var currentDeadline: Date { locked { deadline } }

    private func serveLoop(_ s: SOCKET) {
        defer { _ = closesocket(s) }
        while !isDone {
            if Date() > currentDeadline { finish(.failure(GoogleOAuth.OAuthError.timedOut)); break }
            var fds = [WSAPOLLFD(fd: s, events: 0x0100 | 0x0200, revents: 0)]
            let ready = fds.withUnsafeMutableBufferPointer { WSAPoll($0.baseAddress, 1, 200) }
            guard ready > 0 else { continue }
            let c = accept(s, nil, nil)
            guard c != INVALID_SOCKET else { continue }
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    /// Reads the request line (at most 16 KB, at most 5 s), answers, closes.
    private func serve(_ c: SOCKET) {
        defer { _ = closesocket(c) }
        var buffer = Data()
        let until = Date().addingTimeInterval(5)
        while buffer.count < 16 * 1024, Date() < until {
            if buffer.contains(UInt8(ascii: "\n")) { break }
            var fds = [WSAPOLLFD(fd: c, events: 0x0100 | 0x0200, revents: 0)]
            let ready = fds.withUnsafeMutableBufferPointer { WSAPoll($0.baseAddress, 1, 200) }
            if ready <= 0 { continue }
            var chunk = [CChar](repeating: 0, count: 4096)
            let n = recv(c, &chunk, 4096, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<Int(n)].map { UInt8(bitPattern: $0) })
        }
        let head = String(decoding: buffer, as: UTF8.self)
        let firstLine = head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parameters = GoogleOAuth.redirectParameters(requestLine: firstLine)
        let expected = locked { expectedState }
        let isAnswer = parameters.map { ($0["code"] != nil || $0["error"] != nil) && $0["state"] == expected } ?? false
        let body = isAnswer ? Self.page(appName: appName, ok: parameters?["code"] != nil) : ""
        let status = isAnswer ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { send(c, $0, Int32(p.count), 0) }
            }
            if n <= 0 { break }
            sent += Int(n)
        }
        if isAnswer, let parameters { finish(.success(parameters)) }
    }

    static func page(appName: String, ok: Bool) -> String {
        let title = ok ? "Signed in" : "Sign-in not completed"
        let text = ok ? "You can close this tab and go back to \(appName)."
                      : "Go back to \(appName) and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>\(appName)</title>
            <style>body{font:15px Segoe UI,sans-serif;background:#1e1e1e;color:#eee;\
            display:flex;align-items:center;justify-content:center;height:90vh}</style></head>
            <body><div><h2>\(title)</h2><p>\(text)</p></div></body></html>
            """
    }
}
#endif
#endif

/// First caller wins; for continuations that several callbacks could resume.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
