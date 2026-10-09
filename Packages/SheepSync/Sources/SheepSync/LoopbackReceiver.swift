import Foundation
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
