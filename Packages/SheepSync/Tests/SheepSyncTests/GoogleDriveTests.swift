import Foundation
import XCTest
@testable import SheepSync

/// GoogleDriveBackend against a fake Drive served through URLProtocol — the
/// real request code, no network. Pins the 5.0 (7) review findings: a cached
/// id that 404s is re-listed (not read as "no file"), two Macs creating the
/// same name settle on one file, and `versions` reflects writes.
final class GoogleDriveTests: XCTestCase {
    final class FakeDrive: URLProtocol, @unchecked Sendable {
        struct File { var name: String; var data: Data; var created: Int; var version: Int }
        nonisolated(unsafe) static var files: [String: File] = [:]
        nonisolated(unsafe) static var clock = 0
        /// The next listing answers "no files" — the moment two Macs both
        /// decide to create.
        nonisolated(unsafe) static var hideNextList = false
        static let lock = NSLock()

        static func reset() { lock.withLock { files = [:]; clock = 0; hideNextList = false } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let (status, body) = Self.lock.withLock { Self.handle(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        static func body(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }

        static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

        static func handle(_ request: URLRequest) -> (Int, Data) {
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            if url.host == "oauth2.googleapis.com" {
                return (200, json(["access_token": "t", "expires_in": 3600]))
            }
            let path = url.path
            if method == "GET", path == "/drive/v3/files", hideNextList {
                hideNextList = false
                return (200, json(["files": [Any]()]))
            }
            if method == "GET", path == "/drive/v3/files" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "q" }!.value!
                let names = q.components(separatedBy: "name = '").dropFirst()
                    .map { String($0.prefix { $0 != "'" }) }
                let hits = files.filter { names.contains($0.value.name) }
                    .sorted { $0.value.created < $1.value.created }
                    .map { ["id": $0.key, "name": $0.value.name, "version": String($0.value.version)] }
                return (200, json(["files": hits]))
            }
            if method == "POST", path == "/upload/drive/v3/files" {
                let raw = body(request)
                let text = String(decoding: raw, as: UTF8.self)
                let name = text.components(separatedBy: "\"name\":\"").dropFirst().first.map { String($0.prefix { $0 != "\"" }) } ?? "?"
                let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
                let start = raw.range(of: marker)!.upperBound
                let end = raw.range(of: Data("\r\n--".utf8), options: .backwards)!.lowerBound
                clock += 1
                let id = "id\(clock)"
                files[id] = File(name: name, data: raw[start..<end], created: clock, version: 1)
                return (200, json(["id": id]))
            }
            let id = url.lastPathComponent
            switch method {
            case "GET":
                guard let file = files[id] else { return (404, json(["error": ["message": "not found"]])) }
                return (200, file.data)
            case "PATCH":
                guard files[id] != nil else { return (404, json(["error": ["message": "not found"]])) }
                files[id]!.data = body(request)
                files[id]!.version += 1
                return (200, json(["id": id]))
            case "DELETE":
                files[id] = nil
                return (204, Data())
            default:
                return (400, Data())
            }
        }
    }

    private func backend() -> GoogleDriveBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        let session = URLSession(configuration: configuration)
        let account = GoogleAccount(client: GoogleClient(clientID: "x.apps.googleusercontent.com", clientSecret: nil),
                                    refreshToken: "r", session: session)
        return GoogleDriveBackend(account: account, session: session)
    }

    override func setUp() { FakeDrive.reset() }

    func testRoundTripAndVersions() async throws {
        let drive = backend()
        let none = try await drive.read("a")
        XCTAssertNil(none)
        let noVersions = try await drive.versions(["a"])
        XCTAssertEqual(noVersions, [:])
        try await drive.write("a", Data("one".utf8))
        let before = try await drive.versions(["a", "b"])
        let one = try await drive.read("a")
        XCTAssertEqual(one, Data("one".utf8))
        try await drive.write("a", Data("two".utf8))
        let after = try await drive.versions(["a"])
        XCTAssertNotNil(before["a"])
        XCTAssertNotEqual(before["a"], after["a"])
        let two = try await drive.read("a")
        XCTAssertEqual(two, Data("two".utf8))
        try await drive.delete("a")
        let gone = try await drive.read("a")
        XCTAssertNil(gone)
    }

    /// Regression: another Mac replaced the file (reset), this Mac's cached
    /// id 404s — that used to be read as "no data file at all".
    func testReplacedFileIsFoundAgain() async throws {
        let mine = backend(), other = backend()
        try await mine.write("data", Data("old".utf8))
        let v6 = try await mine.read("data")
        XCTAssertEqual(v6, Data("old".utf8))   // id cached
        try await other.delete("data")
        try await other.write("data", Data("new".utf8))
        let v7 = try await mine.read("data")
        XCTAssertEqual(v7, Data("new".utf8))
    }

    /// Regression: two Macs creating the same name each kept using their
    /// own copy. Both must settle on the oldest.
    func testTwoCreatorsSettleOnOneFile() async throws {
        let a = backend(), b = backend()
        try await a.write("key", Data("from A".utf8))
        // B never listed before A created: simulate the race by creating
        // B's copy straight through the fake (as if both POSTed at once).
        FakeDrive.lock.withLock {
            FakeDrive.clock += 1
            FakeDrive.files["late"] = .init(name: "key", data: Data("from B".utf8), created: FakeDrive.clock, version: 1)
        }
        try await b.write("key", Data("B again".utf8))
        let fromA = try await a.read("key")
        let fromB = try await b.read("key")
        XCTAssertEqual(fromA, fromB, "both Macs read the same copy")
        XCTAssertEqual(fromB, Data("B again".utf8))
    }

    /// The create race proper: B lists, sees nothing (A's create is not
    /// visible yet), creates its own — then must write into the oldest copy
    /// and remove its own, so both Macs use one file.
    func testCreateRaceMergesIntoOldest() async throws {
        let a = backend()
        try await a.write("key", Data("A".utf8))
        let b = backend()
        FakeDrive.lock.withLock { FakeDrive.hideNextList = true }
        try await b.write("key", Data("B".utf8))
        let count = FakeDrive.lock.withLock { FakeDrive.files.values.filter { $0.name == "key" }.count }
        XCTAssertEqual(count, 1, "the extra copy is removed")
        let v8 = try await a.read("key")
        XCTAssertEqual(v8, Data("B".utf8))
        let v9 = try await b.read("key")
        XCTAssertEqual(v9, Data("B".utf8))
    }

    /// Regression: after sign-out, a refresh finishing late wrote a rotated
    /// token back into the Keychain. A revoked account refuses and stores
    /// nothing; concurrent callers share one refresh.
    func testRevokedAccountStoresNothingAndRefreshesOnce() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        let session = URLSession(configuration: configuration)
        let stored = OnceFlag()
        let account = GoogleAccount(client: GoogleClient(clientID: "x.apps.googleusercontent.com", clientSecret: nil),
                                    refreshToken: "r", session: session) { _ in _ = stored.claim() }
        async let t1 = account.token()
        async let t2 = account.token()
        let (a, b) = try await (t1, t2)
        XCTAssertEqual(a, b)
        await account.revoke()
        do { _ = try await account.token(); XCTFail("token after revoke") } catch {
            XCTAssertEqual(error as? GoogleOAuth.OAuthError, .invalidGrant)
        }
        XCTAssertTrue(stored.claim(), "no rotated token was stored (the fake never rotates)")
    }
}
