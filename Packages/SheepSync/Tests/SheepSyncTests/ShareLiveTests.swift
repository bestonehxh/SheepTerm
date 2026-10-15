import Foundation
import XCTest
@testable import SheepSync

/// The whole share path over real HTTP (URLSession, the real loopback sign-in) against Tools/fake-google-share.py — several Google
/// users; the recipient side uses the public download only. Skipped unless SHEEPSYNC_FAKE_GOOGLE=http://127.0.0.1:<port> names a running fake.
///   python3 Tools/fake-google-share.py --port 8791 &   SHEEPSYNC_FAKE_GOOGLE=http://127.0.0.1:8791 ./Tests/run.sh sync-pkg --filter ShareLive
@MainActor
final class ShareLiveTests: XCTestCase {
    private var base: URL!
    private var dirs: [URL] = []

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["SHEEPSYNC_FAKE_GOOGLE"], let url = URL(string: raw), url.host == "127.0.0.1" else {
            throw XCTSkip("SHEEPSYNC_FAKE_GOOGLE not set")
        }
        base = url
        GoogleOAuth.endpointBase = url
    }

    override func tearDown() async throws {
        GoogleOAuth.endpointBase = nil
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base.absoluteString + path)!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// One Mac signed in as `user`.
    private func mac(_ user: String) async throws -> (engine: SyncEngine, records: ShareRecordStore) {
        _ = try await get("/__as?user=\(user)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        dirs.append(dir)
        let secrets = SyncEngineTests.MemorySecrets()
        let engine = SyncEngine(configuration: SyncConfiguration(
            appName: "Live", google: GoogleClient(clientID: "1-x.apps.googleusercontent.com", clientSecret: "s"),
            keychainService: "unused", stateDirectory: dir, deviceName: user), secrets: secrets, transport: .urlSession)
        // The "browser": URLSession follows /auth's 302 to the loopback listener.
        engine.openURL = { url in Task { _ = try? await URLSession.shared.data(from: url) } }
        await engine.signIn()
        XCTAssertEqual(engine.account, user)
        return (engine, ShareRecordStore(directory: dir, secrets: secrets))
    }

    private func request(_ to: [String], creds: Bool, lifetime: ShareLifetime = .week) -> ShareService.Request {
        ShareService.Request(
            groupDocument: Data(#"{"version":1,"sender":"s","group":{"id":"11111111-2222-3333-4444-555555555555","name":"Lab","hosts":[{"id":"22222222-2222-3333-4444-555555555555","name":"sw1","credentialID":"LOCAL","address":"10.0.0.1"}]}}"#.utf8),
            groupName: "Lab", hostCount: 1,
            credentials: creds ? ShareCredentials(entries: [.init(name: "core", username: "admin", password: "hunter2", hosts: ["22222222-2222-3333-4444-555555555555"])]) : nil,
            passphrase: "long enough", recipients: to, lifetime: lifetime)
    }

    private func store(_ tag: String) -> ShareRecordStore {
        ShareRecordStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("live-\(tag)-\(UUID().uuidString)"),
                         secrets: SyncEngineTests.MemorySecrets())
    }

    /// What a recipient's app does: the public download with NO token, then open with the signed-in address.
    private func receive(_ engine: SyncEngine, _ link: SharedLink, passphrase: String) async throws -> ShareContent {
        let downloader = try XCTUnwrap(engine.makeShareDownloader())
        let blob = try await ShareService.download(link, via: downloader)
        return try ShareService.open(blob: blob, link: link, passphrase: passphrase, account: engine.account)
    }

    func testAliceSharesBobImportsOthersRefusedRevokeStopsBob() async throws {
        let (alice, _) = try await mac("alice@example.test")
        XCTAssertFalse(alice.hasGranted(GoogleOAuth.driveFileScope))
        try await alice.authorize(adding: GoogleOAuth.driveFileScope)
        XCTAssertTrue(alice.hasGranted(GoogleOAuth.driveFileScope))
        // Sync still works on the replaced refresh token (the appdata grant was kept).
        try await alice.createVault(passphrase: "sync passphrase")
        XCTAssertEqual(alice.phase, .ready)
        let sender = try XCTUnwrap(alice.makeShareService(records: store("a")))
        let (record, link) = try await sender.create(request(["bob@example.test"], creds: true))

        // Bob signs in for Sync only (no extra scope, ever) and opens the link.
        let (bob, _) = try await mac("bob@example.test")
        XCTAssertFalse(bob.hasGranted(GoogleOAuth.driveFileScope))
        let content = try await receive(bob, link, passphrase: "long enough")
        XCTAssertEqual(content.sender, "alice@example.test")
        XCTAssertEqual(content.name, "Lab")
        XCTAssertEqual(content.credentials?.entries.first?.password, "hunter2")
        XCTAssertFalse(String(decoding: content.group, as: UTF8.self).contains("credentialID"))

        // Wrong passphrase: refused. Right passphrase, signed in as someone else: refused.
        do { _ = try await receive(bob, link, passphrase: "wrong wrong"); XCTFail() } catch { XCTAssertEqual(error as? ShareError, .wrongPassphrase) }
        let (carol, _) = try await mac("carol@example.test")
        do { _ = try await receive(carol, link, passphrase: "long enough"); XCTFail("carol opened it") }
        catch { XCTAssertEqual(error as? ShareError, .notRecipient) }

        // Only the passphrase, with a guessed/other link key: refused too (the file itself is public ciphertext).
        let downloader = try XCTUnwrap(bob.makeShareDownloader())
        let blob = try await ShareService.download(link, via: downloader)
        XCTAssertThrowsError(try ShareService.open(blob: blob, link: SharedLink(fileID: link.fileID, key: Data(repeating: 1, count: 32)),
                                                   passphrase: "long enough", account: "bob@example.test"))
        XCTAssertNil(blob.range(of: Data("bob@example.test".utf8)))

        // Revoke -> the public download is gone.
        try await sender.revoke(record.id)
        do { _ = try await receive(bob, link, passphrase: "long enough"); XCTFail("still readable") }
        catch { XCTAssertEqual(error as? ShareError, .revoked) }

        // Expiry: the file is deleted by the sender's app once past; before that the reader refuses the expired payload.
        let (day, dayLink) = try await sender.create(request(["bob@example.test"], creds: false, lifetime: .day))
        _ = try await receive(bob, dayLink, passphrase: "long enough")
        let blob2 = try await ShareService.download(dayLink, via: downloader)
        XCTAssertThrowsError(try ShareService.open(blob: blob2, link: dayLink, passphrase: "long enough", account: "bob@example.test",
                                                   now: Date().addingTimeInterval(2 * 86_400))) { XCTAssertEqual($0 as? ShareError, .expired) }
        try await sender.revoke(day.id)

        // The server only ever saw "anyone / reader / no discovery", and bob never touched an authenticated Drive endpoint.
        let state = try await get("/__state")
        let permissions = try XCTUnwrap(state["permissions"] as? [[String: Any]])
        XCTAssertEqual(permissions.count, 2)
        for entry in permissions {
            let body = try XCTUnwrap(entry["body"] as? [String: Any])
            XCTAssertEqual(body["type"] as? String, "anyone")
            XCTAssertEqual(body["role"] as? String, "reader")
            XCTAssertEqual(body["allowFileDiscovery"] as? Bool, false)
            XCTAssertNil(body["emailAddress"])
        }
        XCTAssertEqual(state["anonymousDownloads"] as? Int, 7)
    }
}
