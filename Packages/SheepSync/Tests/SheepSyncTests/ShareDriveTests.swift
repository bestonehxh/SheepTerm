import Foundation
import XCTest
@testable import SheepSync

/// GoogleDriveShareBackend's real request code against a fake Drive behind URLProtocol (two users, told apart by bearer token), and the
/// engine's incremental scope request.
final class ShareDriveTests: XCTestCase {
    final class FakeDrive: URLProtocol, @unchecked Sendable {
        struct File { var name: String; var data: Data; var owner: String; var parents: [String]; var isPublic: Bool }
        nonisolated(unsafe) static var files: [String: File] = [:]
        nonisolated(unsafe) static var folders: [String: String] = [:]    // id -> owner
        nonisolated(unsafe) static var permissionBodies: [[String: Any]] = []
        nonisolated(unsafe) static var downloadAuthHeaders: [String?] = []
        /// File ids that first answer with Drive's HTML "confirm" page.
        nonisolated(unsafe) static var confirmFirst: Set<String> = []
        nonisolated(unsafe) static var serial = 0
        static let lock = NSLock()
        static func reset() { lock.withLock { files = [:]; folders = [:]; permissionBodies = []; downloadAuthHeaders = []; confirmFirst = []; serial = 0 } }

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

        static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        static func err(_ code: Int) -> (Int, Data) { (code, json(["error": ["message": "e\(code)"]])) }

        static func body(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        }

        static func handle(_ request: URLRequest) -> (Int, Data) {
            let url = request.url!, method = request.httpMethod ?? "GET"
            if url.host == "oauth2.googleapis.com" { return (200, json(["access_token": "t", "expires_in": 3600])) }
            let user = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func query(_ n: String) -> String? { q.first { $0.name == n }?.value }
            let path = url.path
            // The public download: no token, any caller.
            if url.host == "drive.usercontent.google.com", path == "/download" {
                downloadAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                guard let id = query("id"), let f = files[id], f.isPublic else { return (404, Data("<html>not found</html>".utf8)) }
                if confirmFirst.contains(id), query("confirm") == nil {
                    return (200, Data(#"<!DOCTYPE html><html><body><form action="https://drive.usercontent.google.com/download" method="get"><input type="hidden" name="id" value="\#(id)"><input type="hidden" name="export" value="download"><input type="hidden" name="confirm" value="t"><input type="hidden" name="uuid" value="u-1"></form></body></html>"#.utf8))
                }
                if confirmFirst.contains(id), query("uuid") != "u-1" { return (404, Data()) }
                return (200, f.data)
            }
            if method == "GET", path == "/drive/v3/files" {
                let text = query("q") ?? ""
                if text.contains("mimeType = 'application/vnd.google-apps.folder'") {
                    return (200, json(["files": folders.filter { $0.value == user }.keys.sorted().map { ["id": $0] }]))
                }
                return (200, json(["files": [Any]()]))
            }
            if method == "POST", path == "/drive/v3/files" {
                serial += 1
                let id = "folder\(serial)xxxxxxxx"
                folders[id] = user
                return (200, json(["id": id]))
            }
            if method == "POST", path == "/upload/drive/v3/files" {
                let raw = body(request)
                let text = String(decoding: raw, as: UTF8.self)
                let name = text.components(separatedBy: "\"name\":\"").dropFirst().first.map { String($0.prefix { $0 != "\"" }) } ?? "?"
                let parent = text.components(separatedBy: "\"parents\":[\"").dropFirst().first.map { String($0.prefix { $0 != "\"" }) } ?? ""
                let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
                let start = raw.range(of: marker)!.upperBound
                let end = raw.range(of: Data("\r\n--".utf8), options: .backwards)!.lowerBound
                serial += 1
                let id = "file\(serial)xxxxxxxxxx"
                files[id] = File(name: name, data: raw[start..<end], owner: user, parents: [parent], isPublic: false)
                return (200, json(["id": id]))
            }
            let parts = path.split(separator: "/").map(String.init)      // drive v3 files <id> [permissions]
            guard parts.count >= 4, parts[0] == "drive" else { return err(400) }
            let id = parts[3]
            guard let file = files[id], file.owner == user else { return err(404) }
            if parts.count == 5, parts[4] == "permissions", method == "POST" {
                let object = (try? JSONSerialization.jsonObject(with: body(request))) as? [String: Any] ?? [:]
                permissionBodies.append(object)
                guard object["type"] as? String == "anyone", object["role"] as? String == "reader",
                      object["allowFileDiscovery"] as? Bool == false, object["emailAddress"] == nil else { return err(400) }
                files[id]!.isPublic = true
                return (200, json(["id": "perm"]))
            }
            if method == "DELETE" { files[id] = nil; return (204, Data()) }
            return err(400)
        }
    }

    final class StubAccount: GoogleAccountProtocol, @unchecked Sendable {
        let user: String
        init(_ user: String) { self.user = user }
        func token() async throws -> String { user }
        func invalidate() async {}
        func profile() async -> GoogleOAuth.Profile? { nil }
        func revoke() async {}
    }

    private func backend(_ user: String) -> GoogleDriveShareBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        return GoogleDriveShareBackend(account: StubAccount(user), session: URLSession(configuration: configuration))
    }

    override func setUp() { FakeDrive.reset() }

    func testPermissionRequestIsExactlyAnonymousReaderWithoutDiscovery() throws {
        let request = GoogleDriveShareBackend.permissionRequest(fileID: "abc")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url!.path.hasSuffix("/files/abc/permissions"))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["type", "role", "allowFileDiscovery"])
        XCTAssertEqual(body["type"] as? String, "anyone")
        XCTAssertEqual(body["role"] as? String, "reader")
        XCTAssertEqual(body["allowFileDiscovery"] as? Bool, false)
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertFalse(text.contains("domain")); XCTAssertFalse(text.contains("emailAddress")); XCTAssertFalse(text.contains("expirationTime"))
    }

    func testSenderUploadsAndRecipientDownloadsWithoutAnyToken() async throws {
        let lab = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        let alice = ShareService(backend: backend("a@gmail.com"), sender: "a@gmail.com",
                                 records: ShareRecordStore(directory: lab, secrets: SyncEngineTests.MemorySecrets()))
        let req = ShareService.Request(groupDocument: Data(#"{"group":{"name":"Lab","hosts":[{"name":"s","credentialID":"x"}]}}"#.utf8),
                                       groupName: "Lab", hostCount: 1, credentials: nil, passphrase: "long enough",
                                       recipients: ["b@gmail.com"], lifetime: .day)
        let (record, link) = try await alice.create(req)
        let state = FakeDrive.lock.withLock { (FakeDrive.folders, FakeDrive.files[record.id]!, FakeDrive.permissionBodies) }
        XCTAssertEqual(state.0.count, 1)
        XCTAssertEqual(state.1.parents, [state.0.keys.first!])
        XCTAssertTrue(state.1.name.hasPrefix("SheepTerm share "))
        XCTAssertTrue(state.1.isPublic)
        XCTAssertEqual(state.2.count, 1)
        XCTAssertEqual(state.2[0]["type"] as? String, "anyone")
        _ = try await alice.create(req)
        XCTAssertEqual(FakeDrive.lock.withLock { FakeDrive.folders.count }, 1, "the second share reuses the folder")

        // Recipient: plain session, no account, no scope.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        let downloader = PublicDriveDownloader(session: URLSession(configuration: configuration))
        let blob = try await ShareService.download(link, via: downloader)
        XCTAssertEqual(blob, state.1.data)
        XCTAssertEqual(FakeDrive.lock.withLock { FakeDrive.downloadAuthHeaders }, [nil], "the download carries no Authorization header")
        let content = try ShareService.open(blob: blob, link: link, passphrase: "long enough", account: "b@gmail.com")
        XCTAssertEqual(content.name, "Lab")
        // Anyone can fetch the ciphertext; nobody can read it with half the secrets.
        XCTAssertThrowsError(try ShareService.open(blob: blob, link: link, passphrase: "wrong wrong", account: "b@gmail.com"))
        XCTAssertThrowsError(try ShareService.open(blob: blob, link: SharedLink(fileID: link.fileID, key: Data(repeating: 7, count: 32)),
                                                   passphrase: "long enough", account: "b@gmail.com"))
        XCTAssertThrowsError(try ShareService.open(blob: blob, link: link, passphrase: "long enough", account: "carol@gmail.com")) {
            XCTAssertEqual($0 as? ShareError, .notRecipient)
        }
        // Revoke -> 404 -> "revoked".
        try await alice.revoke(record.id)
        do { _ = try await ShareService.download(link, via: downloader); XCTFail() } catch { XCTAssertEqual(error as? ShareError, .revoked) }
        try await backend("a@gmail.com").delete(fileID: record.id)    // gone already: not an error
    }

    func testDriveConfirmPageIsFollowedOnce() async throws {
        let account = backend("a@gmail.com")
        let id = try await account.upload(name: "big", data: Data("ciphertext".utf8))
        try await account.makePublic(fileID: id)
        FakeDrive.lock.withLock { FakeDrive.confirmFirst = [id] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        let data = try await PublicDriveDownloader(session: URLSession(configuration: configuration)).download(fileID: id)
        XCTAssertEqual(data, Data("ciphertext".utf8))
        // A file that is not public, or any HTML page without a confirm form, is "gone".
        let hidden = try await account.upload(name: "private", data: Data("x".utf8))
        do { _ = try await PublicDriveDownloader(session: URLSession(configuration: configuration)).download(fileID: hidden); XCTFail() }
        catch { XCTAssertEqual(error as? SyncBackendError, .http(404, "download failed")) }
    }

    func testHTMLHelpers() {
        XCTAssertTrue(PublicDriveDownloader.looksLikeHTML(Data("  <!DOCTYPE html><p>".utf8)))
        XCTAssertFalse(PublicDriveDownloader.looksLikeHTML(Data("SSL2".utf8) + Data([0, 1, 2])))
        let form = PublicDriveDownloader.hiddenInputs(in: Data(#"<input type="hidden" name="id" value="a&amp;b"><input type="hidden" name="confirm" value="t">"#.utf8))
        XCTAssertEqual(form, ["id": "a&b", "confirm": "t"])
    }

    // MARK: Incremental scopes

    @MainActor
    func testIncrementalAuthorizationAddsOneScopeAndKeepsSync() async throws {
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var urls: [URL] = []; var answers: [GoogleOAuth.TokenResponse] = []; var exchanges = 0
            func take() -> GoogleOAuth.TokenResponse { lock.withLock { exchanges += 1; return answers.removeFirst() } }
        }
        let log = Log()
        let appdata = ["https://www.googleapis.com/auth/drive.appdata", "openid", "email", "profile"]
        log.answers = [
            GoogleOAuth.TokenResponse(accessToken: "a1", expiresIn: 3600, refreshToken: "r1", email: "a@gmail.com", picture: nil, scopes: appdata),
            // Somebody else's account picked in the browser.
            GoogleOAuth.TokenResponse(accessToken: "a2", expiresIn: 3600, refreshToken: "rX", email: "other@gmail.com", picture: nil,
                                      scopes: appdata + [GoogleOAuth.driveFileScope]),
            GoogleOAuth.TokenResponse(accessToken: "a3", expiresIn: 3600, refreshToken: "r2", email: "a@gmail.com", picture: nil,
                                      scopes: appdata + [GoogleOAuth.driveFileScope]),
        ]
        let transport = GoogleTransport(
            exchangeCode: { _, _, _, _ in log.take() },
            makeAccount: { _, _, _ in (StubAccount("a@gmail.com"), MemorySyncBackend()) },
            makeShareBackend: { _ in MemoryShareBackend(user: "a@gmail.com") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = SyncEngineTests.MemorySecrets()
        let engine = SyncEngine(configuration: SyncConfiguration(
            appName: "TestApp", google: GoogleClient(clientID: "1-x.apps.googleusercontent.com", clientSecret: nil),
            keychainService: "unused", stateDirectory: dir, deviceName: "M", debounce: .milliseconds(10), interval: .seconds(3600)),
            secrets: secrets, transport: transport)
        // Opening the "browser" = following the redirect ourselves.
        engine.openURL = { url in
            log.lock.withLock { log.urls.append(url) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=c&state=\(state)")!) }
        }
        engine.dataSource = nil

        // Not signed in: refused, nothing opened.
        do { try await engine.authorize(adding: GoogleOAuth.driveFileScope); XCTFail() } catch { XCTAssertEqual(error as? ShareError, .notSignedIn) }
        XCTAssertTrue(log.urls.isEmpty)

        await engine.signIn()
        XCTAssertEqual(engine.account, "a@gmail.com")
        XCTAssertFalse(engine.hasGranted(GoogleOAuth.driveFileScope))
        let signInScopes = URLComponents(url: log.urls[0], resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
        XCTAssertEqual(signInScopes, appdata.joined(separator: " "), "sign-in still asks for the appdata scope only")
        XCTAssertFalse(log.urls[0].absoluteString.contains("include_granted_scopes"))
        let phase = engine.phase
        XCTAssertEqual(SyncEngine.refreshToken(in: secrets), "r1")

        // Wrong account in the browser: nothing stored.
        do { try await engine.authorize(adding: GoogleOAuth.driveFileScope); XCTFail() }
        catch { XCTAssertEqual(error as? SyncEngineError, .differentAccount("a@gmail.com")) }
        XCTAssertEqual(SyncEngine.refreshToken(in: secrets), "r1")
        XCTAssertFalse(engine.hasGranted(GoogleOAuth.driveFileScope))
        XCTAssertFalse(engine.isAuthorizing)

        try await engine.authorize(adding: GoogleOAuth.driveFileScope)
        let items = URLComponents(url: log.urls[2], resolvingAgainstBaseURL: false)!.queryItems!
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(item("scope"), "\(GoogleOAuth.driveFileScope) openid email")
        XCTAssertEqual(item("include_granted_scopes"), "true")
        XCTAssertEqual(item("login_hint"), "a@gmail.com")
        XCTAssertEqual(item("prompt"), "consent")
        XCTAssertTrue(engine.hasGranted(GoogleOAuth.driveFileScope))
        XCTAssertTrue(engine.hasGranted(appdata[0]), "the earlier grant is kept")
        XCTAssertEqual(SyncEngine.refreshToken(in: secrets), "r2")
        XCTAssertEqual(engine.phase, phase, "Sync's phase is untouched")
        XCTAssertNotNil(engine.makeShareService(records: ShareRecordStore(directory: dir, secrets: secrets)))
        // Granted already: no second browser round trip.
        try await engine.authorize(adding: GoogleOAuth.driveFileScope)
        XCTAssertEqual(log.urls.count, 3)

        // A fresh engine on the same files remembers the grant.
        let again = SyncEngine(configuration: SyncConfiguration(
            appName: "TestApp", google: GoogleClient(clientID: "1-x.apps.googleusercontent.com", clientSecret: nil),
            keychainService: "unused", stateDirectory: dir, deviceName: "M"), secrets: secrets, transport: transport)
        XCTAssertTrue(again.hasGranted(GoogleOAuth.driveFileScope))
    }

    func testTokenResponseCarriesTheGrantedScopes() throws {
        let data = Data(#"{"access_token":"t","expires_in":3600,"refresh_token":"r","scope":"openid https://www.googleapis.com/auth/drive.file email"}"#.utf8)
        XCTAssertEqual(try GoogleOAuth.parseTokenResponse(data, status: 200).scopes,
                       ["openid", "https://www.googleapis.com/auth/drive.file", "email"])
        XCTAssertNil(try GoogleOAuth.parseTokenResponse(Data(#"{"access_token":"t"}"#.utf8), status: 200).scopes)
    }
}

