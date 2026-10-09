import XCTest
@testable import SheepSync

/// Two (or three) Macs against one in-memory "Drive": the whole engine —
/// vault creation, joining, edits both ways, deletes, unreadable records,
/// failed uploads/applies, and a reset on another Mac — without Google.
@MainActor
final class SyncEngineTests: XCTestCase {
    final class MemorySecrets: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        func read(_ account: String) -> Data? { lock.withLock { items[account] } }
        func write(_ account: String, _ value: Data) -> Bool { lock.withLock { items[account] = value }; return true }
        func delete(_ account: String) -> Bool { lock.withLock { items[account] = nil }; return true }
        var accounts: Set<String> { lock.withLock { Set(items.keys) } }
    }

    final class FakeApp: SyncDataSource {
        var records: [String: Data] = [:]
        var unavailable: Set<String> = []
        var wantCloud: Set<String> = []
        var refuse: Set<String> = []
        var applied: [[String: Data?]] = []
        var joins: [Bool] = []

        func syncSnapshot() -> SyncSnapshot {
            SyncSnapshot(records: records, unavailable: unavailable, wantCloudCopy: wantCloud)
        }

        /// Refuse a join outright (the app could not set its data aside).
        var refuseJoin = false

        func syncApply(_ changes: [String: Data?], firstJoin: Bool) -> SyncApplyResult {
            applied.append(changes)
            joins.append(firstJoin)
            if firstJoin, refuseJoin { return SyncApplyResult(failed: Set(changes.keys), refusedJoin: true) }
            var failed: Set<String> = []
            for (id, value) in changes {
                if refuse.contains(id) { failed.insert(id); continue }
                records[id] = value
            }
            return SyncApplyResult(failed: failed)
        }

        subscript(_ id: String) -> String? {
            get { records[id].map { String(decoding: $0, as: UTF8.self) } }
            set { records[id] = newValue.map { Data($0.utf8) } }
        }
    }

    struct Mac {
        let engine: SyncEngine
        let app: FakeApp
        let secrets: MemorySecrets
        let config: SyncConfiguration
    }

    var drive: MemorySyncBackend!
    var dirs: [URL] = []

    override func setUp() async throws {
        drive = MemorySyncBackend()
    }

    override func tearDown() async throws {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeMac(_ name: String, signedIn: Bool = true, dir: URL? = nil, secrets: MemorySecrets? = nil) -> Mac {
        let directory = dir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepsync-test-\(UUID().uuidString)")
        dirs.append(directory)
        let config = SyncConfiguration(
            appName: "TestApp", google: GoogleClient(clientID: "1-x.apps.googleusercontent.com", clientSecret: nil),
            keychainService: "unused", stateDirectory: directory, deviceName: name,
            debounce: .milliseconds(10), interval: .seconds(3600))
        let secrets = secrets ?? MemorySecrets()
        if signedIn { SyncEngine.setRefreshToken("refresh", in: secrets) }
        let drive = self.drive!
        let engine = SyncEngine(configuration: config, secrets: secrets, makeBackend: { _ in drive })
        let app = FakeApp()
        engine.dataSource = app
        return Mac(engine: engine, app: app, secrets: secrets, config: config)
    }

    private func vault(_ mac: Mac, create passphrase: String) async throws {
        await mac.engine.checkVault()
        XCTAssertEqual(mac.engine.phase, .needsNewPassphrase)
        try await mac.engine.createVault(passphrase: passphrase)
        XCTAssertEqual(mac.engine.phase, .ready)
        await mac.engine.syncNow()
    }

    private func join(_ mac: Mac, _ passphrase: String) async throws {
        await mac.engine.checkVault()
        XCTAssertEqual(mac.engine.phase, .needsPassphrase)
        try await mac.engine.unlock(passphrase: passphrase)
        await mac.engine.syncNow()
    }

    func testUnconfiguredBuildNeverLeavesNotConfigured() {
        let config = SyncConfiguration(appName: "X", google: GoogleClient(clientID: "", clientSecret: nil),
                                       keychainService: "x", stateDirectory: URL(fileURLWithPath: "/nonexistent"),
                                       deviceName: "M")
        let engine = SyncEngine(configuration: config, secrets: MemorySecrets(), makeBackend: { _ in MemorySyncBackend() })
        XCTAssertEqual(engine.phase, .notConfigured)
    }

    func testSignedOutBuildDoesNothing() async {
        let mac = makeMac("A", signedIn: false)
        XCTAssertEqual(mac.engine.phase, .signedOut)
        mac.app["hosts"] = "h"
        await mac.engine.syncNow()
        let files = await drive.files
        XCTAssertTrue(files.isEmpty, "nothing leaves the Mac before sign-in")
    }

    func testCloudHoldsOnlySealedData() async throws {
        let a = makeMac("A")
        a.app["pw:1"] = "hunter2-very-secret"
        a.app["hosts"] = "router-core-01"
        try await vault(a, create: "pass")
        let files = await drive.files
        XCTAssertEqual(Set(files.keys), ["sheepsync-vault-key.json", "testapp-sync.sealed"])
        for (_, data) in files {
            XCTAssertNil(data.range(of: Data("hunter2".utf8)))
            XCTAssertNil(data.range(of: Data("router-core".utf8)))
        }
    }

    func testSecondMacJoinsTakesTheCloudAndEditsFlowBothWays() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "A's hosts"
        a.app["pw:1"] = "secret1"
        try await vault(a, create: "pass")

        let b = makeMac("B")
        b.app["hosts"] = "fresh default"
        b.app["snippets"] = "B only"
        try await join(b, "pass")
        XCTAssertEqual(b.app["hosts"], "A's hosts", "joining takes the vault's copy")
        XCTAssertEqual(b.app["pw:1"], "secret1")
        XCTAssertEqual(b.app.joins, [true])

        // A sees B's snippet, and B's default never reached the cloud.
        await a.engine.syncNow()
        XCTAssertEqual(a.app["snippets"], "B only")
        XCTAssertEqual(a.app["hosts"], "A's hosts")

        // Edit on B → A.
        try await Task.sleep(for: .milliseconds(5))
        b.app["hosts"] = "B edited"
        await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "B edited")

        // Delete on A → B.
        a.app["pw:1"] = nil
        await a.engine.syncNow()
        await b.engine.syncNow()
        XCTAssertNil(b.app["pw:1"])
        XCTAssertEqual(b.app.joins.last, false)
    }

    func testWrongPassphraseIsRefusedAndNothingChanges() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "right")
        let b = makeMac("B")
        b.app["hosts"] = "mine"
        await b.engine.checkVault()
        do {
            try await b.engine.unlock(passphrase: "wrong")
            XCTFail("unlocked with the wrong passphrase")
        } catch {
            XCTAssertEqual(error as? VaultCryptoError, .wrongPassphrase)
        }
        XCTAssertEqual(b.engine.phase, .needsPassphrase)
        XCTAssertEqual(b.app["hosts"], "mine")
    }

    func testSecondVaultCannotBeCreatedOverAnExistingOne() async throws {
        let a = makeMac("A")
        try await vault(a, create: "one")
        let b = makeMac("B")
        await b.engine.checkVault()
        do {
            try await b.engine.createVault(passphrase: "two")
            XCTFail("overwrote the vault key")
        } catch {
            XCTAssertEqual(error as? SyncEngineError, .vaultAlreadyExists)
        }
        XCTAssertEqual(b.engine.phase, .needsPassphrase)
    }

    func testUnreadableRecordIsNotDeletedEverywhere() async throws {
        let a = makeMac("A")
        a.app["pw:1"] = "s"
        try await vault(a, create: "p")
        // The Keychain item cannot be read this time.
        a.app.records["pw:1"] = nil
        a.app.unavailable = ["pw:1"]
        a.app.refuse = ["pw:1"]
        await a.engine.syncNow()
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertEqual(b.app["pw:1"], "s")
    }

    func testFailedUploadLeavesEverythingToTheNextSync() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "v1"
        try await vault(a, create: "p")
        a.app["hosts"] = "v2"
        await drive.setFailNextWrite()
        await a.engine.syncNow()
        XCTAssertNotNil(a.engine.lastError)
        await a.engine.syncNow()
        XCTAssertNil(a.engine.lastError)
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertEqual(b.app["hosts"], "v2")
    }

    func testFailedApplyIsRetriedAndNeverPushesTheStaleValue() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "cloud"
        try await vault(a, create: "p")
        let b = makeMac("B")
        b.app["hosts"] = "stale"
        b.app.refuse = ["hosts"]
        try await join(b, "p")
        XCTAssertEqual(b.app["hosts"], "stale")
        XCTAssertNotNil(b.engine.lastError)
        // Still refused: B must not upload "stale" as a fresh edit.
        await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "cloud")
        b.app.refuse = []
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "cloud")
    }

    func testResetOnOneMacLocksTheOthersOut() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "old")
        let b = makeMac("B")
        try await join(b, "old")
        try await a.engine.resetVault()
        XCTAssertEqual(a.engine.phase, .needsNewPassphrase)
        try await a.engine.createVault(passphrase: "new")
        await a.engine.syncNow()
        // A's data is the new vault's content.
        let c = makeMac("C")
        try await join(c, "new")
        XCTAssertEqual(c.app["hosts"], "h")
        // B, still holding the old key, must stop and ask.
        b.app["hosts"] = "edit with old key"
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.phase, .needsPassphrase)
        try await b.engine.unlock(passphrase: "new")
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "h", "a Mac re-joining a reset vault takes the cloud's copy")
    }

    func testPassphraseChangeKeepsTheDataReadable() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "old")
        try await a.engine.changePassphrase(current: "old", new: "new")
        await a.engine.syncNow()
        XCTAssertNil(a.engine.lastError)
        let b = makeMac("B")
        await b.engine.checkVault()
        do { try await b.engine.unlock(passphrase: "old"); XCTFail() } catch {}
        try await b.engine.unlock(passphrase: "new")
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "h")
    }

    func testRelaunchResumesReadyWithoutThePassphrase() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        let again = makeMac("A", dir: a.config.stateDirectory, secrets: a.secrets)
        XCTAssertEqual(again.engine.phase, .ready)
        again.app["hosts"] = "h"
        again.app["snippets"] = "new"
        await again.engine.syncNow()
        XCTAssertEqual(again.app.applied.count, 0, "a relaunch is not a join")
    }

    /// Both secrets live in ONE Keychain item: one access prompt, not two,
    /// when the app's signature changes.
    func testSecretsShareOneKeychainItem() async throws {
        let a = makeMac("A")
        try await vault(a, create: "p")
        XCTAssertNotNil(SyncEngine.refreshToken(in: a.secrets))
        XCTAssertNotNil(SyncEngine.vaultKey(in: a.secrets))
        XCTAssertEqual(a.secrets.accounts, [SyncEngine.sessionAccount])
    }

    func testSignOutForgetsKeyAndTokenButNotTheData() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        await a.engine.signOut()
        XCTAssertEqual(a.engine.phase, .signedOut)
        XCTAssertNil(SyncEngine.refreshToken(in: a.secrets))
        XCTAssertNil(SyncEngine.vaultKey(in: a.secrets))
        XCTAssertEqual(a.app["hosts"], "h")
        let files = await drive.files
        XCTAssertEqual(files.count, 2, "the cloud copy is left for the other Macs")
    }

    /// Round 6: an edit made while signed out survives signing back in to
    /// the same vault (it used to be a join, and the cloud's older copy won).
    func testEditWhileSignedOutSurvivesSigningBackIn() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "v1"
        try await vault(a, create: "p")
        await a.engine.signOut()
        try await Task.sleep(for: .milliseconds(5))
        a.app["hosts"] = "edited while signed out"
        // Signing in again = a refresh token in the Keychain, same state dir.
        SyncEngine.setRefreshToken("r2", in: a.secrets)
        let again = makeMac("A", dir: a.config.stateDirectory, secrets: a.secrets)
        again.app.records = a.app.records
        XCTAssertEqual(again.engine.phase, .checkingVault)
        try await join(again, "p")
        XCTAssertEqual(again.app["hosts"], "edited while signed out")
        XCTAssertEqual(again.app.joins.filter { $0 }.count, 0, "not a join")
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertEqual(b.app["hosts"], "edited while signed out")
    }

    // MARK: Regressions from the review (5.0 (7))

    /// Sign Out while Unlock was checking the passphrase: the unlock used to
    /// finish afterwards, write the key back and claim "ready" with no
    /// backend.
    func testSignOutDuringUnlockWins() async throws {
        let a = makeMac("A")
        try await vault(a, create: "p")
        let b = makeMac("B")
        await b.engine.checkVault()
        await drive.setDelays(read: .milliseconds(150), write: nil)
        let unlocking = Task { try await b.engine.unlock(passphrase: "p") }
        try await Task.sleep(for: .milliseconds(30))
        await b.engine.signOut()
        do { try await unlocking.value; XCTFail("unlock survived sign-out") } catch {
            XCTAssertEqual(error as? SyncEngineError, .superseded)
        }
        XCTAssertEqual(b.engine.phase, .signedOut)
        XCTAssertNil(SyncEngine.vaultKey(in: b.secrets))
    }

    /// Reset while a sync was uploading: the upload used to land after the
    /// delete, leaving old-key data the new vault could never open.
    func testResetDuringSyncLeavesNoOldKeyData() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "old")
        a.app["hosts"] = "h2"
        await drive.setDelays(read: nil, write: .milliseconds(150))
        let syncing = Task { await a.engine.syncNow() }
        try await Task.sleep(for: .milliseconds(30))
        try await a.engine.resetVault()
        await syncing.value
        await drive.setDelays(read: nil, write: nil)
        let files = await drive.files
        XCTAssertTrue(files.isEmpty, "reset must leave nothing behind: \(files.keys)")
        try await a.engine.createVault(passphrase: "new")
        await a.engine.syncNow()
        XCTAssertNil(a.engine.lastError)
        let c = makeMac("C")
        try await join(c, "new")
        XCTAssertNil(c.engine.lastError)
        XCTAssertEqual(c.app["hosts"], "h2")
    }

    /// A record unreadable here while the cloud deletes it: once readable
    /// again it used to look like a fresh re-creation and come back on
    /// every Mac.
    func testUnreadableRecordDeletedElsewhereDoesNotComeBack() async throws {
        let a = makeMac("A")
        a.app["pw:1"] = "s"
        try await vault(a, create: "p")
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertEqual(b.app["pw:1"], "s")
        // A deletes it.
        try await Task.sleep(for: .milliseconds(5))
        a.app["pw:1"] = nil
        await a.engine.syncNow()
        // B cannot read (or delete) it right now.
        let kept = b.app.records["pw:1"]
        b.app.records["pw:1"] = nil
        b.app.unavailable = ["pw:1"]
        b.app.refuse = ["pw:1"]
        await b.engine.syncNow()
        // Readable again.
        b.app.records["pw:1"] = kept
        b.app.unavailable = []
        b.app.refuse = []
        await b.engine.syncNow()
        XCTAssertNil(b.app["pw:1"], "the deletion reaches B once it can act on it")
        await a.engine.syncNow()
        XCTAssertNil(a.app["pw:1"], "and the record does not come back to A")
    }

    /// The app refusing a join (it could not set the old configuration
    /// aside) must stay a join on the next sync too — not be applied then
    /// without the safety copy.
    func testRefusedJoinStaysAJoin() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "cloud"
        try await vault(a, create: "p")
        let b = makeMac("B")
        b.app["hosts"] = "mine"
        b.app.refuseJoin = true
        try await join(b, "p")
        await b.engine.syncNow()
        XCTAssertEqual(b.app.joins, [true, true])
        XCTAssertEqual(b.app["hosts"], "mine")
        b.app.refuseJoin = false
        await b.engine.syncNow()
        XCTAssertEqual(b.app.joins.last, true)
        XCTAssertEqual(b.app["hosts"], "cloud")
    }

    /// Round 2: ONE record that keeps failing during the join (an orphan
    /// password) must not keep the Mac in join mode — each later sync would
    /// be another join that stamps local edits 0 and lets the cloud win.
    func testOneFailingRecordDoesNotKeepTheMacJoining() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "cloud"
        a.app["pw:orphan"] = "x"
        try await vault(a, create: "p")
        let b = makeMac("B")
        b.app.refuse = ["pw:orphan"]
        try await join(b, "p")
        XCTAssertEqual(b.app["hosts"], "cloud")
        try await Task.sleep(for: .milliseconds(5))
        b.app["hosts"] = "edited on B"
        await b.engine.syncNow()
        XCTAssertFalse(b.app.joins.dropFirst().contains(true), "no further joins: \(b.app.joins)")
        XCTAssertEqual(b.app["hosts"], "edited on B", "B's edit was not reverted")
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "edited on B")
    }

    /// A quarantined local copy takes the cloud's copy even when that is
    /// not newer than the last sync.
    func testWantCloudCopyRecovers() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "good"
        try await vault(a, create: "p")
        a.app.records["hosts"] = nil
        a.app.unavailable = ["hosts"]
        a.app.wantCloud = ["hosts"]
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "good")
    }

    /// An edit made while the upload was in flight must survive the apply
    /// that follows it, and reach the cloud on the next sync.
    func testEditDuringUploadIsNotOverwritten() async throws {
        let a = makeMac("A")
        a.app["x"] = "x1"
        try await vault(a, create: "p")
        let b = makeMac("B")
        try await join(b, "p")
        try await Task.sleep(for: .milliseconds(5))
        a.app["x"] = "x2"            // cloud will win x on B…
        await a.engine.syncNow()
        b.app["y"] = "y1"            // …while B uploads its own y
        await drive.setDelays(read: nil, write: .milliseconds(150))
        let syncing = Task { await b.engine.syncNow() }
        try await Task.sleep(for: .milliseconds(60))
        b.app["x"] = "typed on B during the upload"
        await syncing.value
        await drive.setDelays(read: nil, write: nil)
        XCTAssertEqual(b.app["x"], "typed on B during the upload")
        await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertEqual(a.app["x"], "typed on B during the upload")
        XCTAssertEqual(a.app["y"], "y1")
    }

    /// After resetting here, unlocking a vault ANOTHER Mac created meanwhile
    /// is a join: this Mac's data must not overwrite that vault.
    func testUnlockingSomeoneElsesNewVaultAfterResetIsAJoin() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "A old"
        try await vault(a, create: "p")
        try await a.engine.resetVault()
        let b = makeMac("B")
        b.app["hosts"] = "B data"
        await b.engine.checkVault()
        try await b.engine.createVault(passphrase: "q")
        await b.engine.syncNow()
        do { try await a.engine.createVault(passphrase: "mine"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncEngineError, .vaultAlreadyExists)
        }
        try await a.engine.unlock(passphrase: "q")
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "B data")
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "B data")
    }

    /// A data file left without a key file (a half-finished reset) is
    /// cleared by the next vault, not read as damaged forever.
    func testNewVaultClearsDebrisDataFile() async throws {
        await drive.overwrite("testapp-sync.sealed", Data("SSV1 junk from an old vault......".utf8))
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        XCTAssertNil(a.engine.lastError)
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertEqual(b.app["hosts"], "h")
    }

    /// Data sealed under another vault's key is never read as this vault's:
    /// nothing from it is applied, and (round 2) it is replaced as debris
    /// rather than reported as damaged forever.
    func testDataFromAnotherVaultIsRefused() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        let stolen = await drive.files["testapp-sync.sealed"]
        // A different vault in a different "account".
        let other = MemorySyncBackend()
        let c = SyncEngine(configuration: makeMac("C", signedIn: false).config, secrets: {
            let s = MemorySecrets(); SyncEngine.setRefreshToken("r", in: s); return s }(),
            makeBackend: { _ in other })
        let app = FakeApp()
        c.dataSource = app
        await c.checkVault()
        try await c.createVault(passphrase: "p")
        await other.overwrite("testapp-sync.sealed", stolen)
        await c.syncNow()
        XCTAssertNil(c.lastError)
        XCTAssertTrue(app.applied.isEmpty, "nothing from the other vault was applied")
        let replaced = await other.files["testapp-sync.sealed"]
        XCTAssertNotEqual(replaced, stolen)
    }

    /// "Lighter" sync: when nothing changed anywhere, a sync downloads
    /// nothing (only the version listing); a change on another Mac is still
    /// picked up.
    func testQuietSyncDownloadsNothing() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        await a.engine.syncNow()        // first sync after our own upload reads once
        let before = await drive.reads
        await a.engine.syncNow()
        await a.engine.syncNow()
        let after = await drive.reads
        XCTAssertEqual(after, before, "no downloads when nothing changed")
        let b = makeMac("B")
        try await join(b, "p")
        try await Task.sleep(for: .milliseconds(5))
        b.app["hosts"] = "from B"
        await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "from B")
    }

    // MARK: Round-2 review

    /// Drive counts versions per file: a re-created key file can carry the
    /// version we cached. The cache must still see the reset.
    func testResetElsewhereSeenThroughTheVersionCache() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "old")
        let b = makeMac("B")
        try await join(b, "old")
        await b.engine.syncNow()                 // B's cache now holds the old key file
        try await a.engine.resetVault()
        try await a.engine.createVault(passphrase: "new")   // key file: new id, version 1 again
        b.app["hosts"] = "B edits with the old key"
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.phase, .needsPassphrase)
        await a.engine.syncNow()
        XCTAssertNil(a.engine.lastError, "A's new vault was not polluted by B")
    }

    /// Old-key data next to the new key file (a write racing a reset) is
    /// replaced, not "damaged" forever.
    func testForeignDataFileIsReplaced() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        let header = SyncEngine.dataMagic + Data("0123456789abcdef".utf8)
        await drive.overwrite("testapp-sync.sealed", header + Data(repeating: 7, count: 64))
        await a.engine.syncNow()
        XCTAssertNil(a.engine.lastError)
        let b = makeMac("B")
        try await join(b, "p")
        XCTAssertNil(b.engine.lastError)
        XCTAssertEqual(b.app["hosts"], "h")
    }

    /// A data file with no header at all is not silently replaced.
    func testHeaderlessDataFileIsAnErrorNotDebris() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        await drive.overwrite("testapp-sync.sealed", Data(repeating: 1, count: 80))
        await a.engine.syncNow()
        XCTAssertNotNil(a.engine.lastError)
        // Reset is the way out, and it must not leave that message behind.
        try await a.engine.resetVault()
        XCTAssertNil(a.engine.lastError, "a reset clears the old vault's error")
    }

    /// No sync may start while a reset is deleting the vault.
    func testNoSyncStartsDuringReset() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        await drive.setDelays(read: nil, write: nil, delete: .milliseconds(100))
        let resetting = Task { try await a.engine.resetVault() }
        try await Task.sleep(for: .milliseconds(30))
        a.app["hosts"] = "edited during reset"
        await a.engine.syncNow()
        try await resetting.value
        await drive.setDelays(read: nil, write: nil, delete: nil)
        let files = await drive.files
        XCTAssertTrue(files.isEmpty, "nothing written during the reset: \(files.keys)")
        try await a.engine.createVault(passphrase: "q")
        await a.engine.syncNow()
        let c = makeMac("C")
        try await join(c, "q")
        XCTAssertEqual(c.app["hosts"], "edited during reset", "the resetting Mac's data is the new vault")
    }

    /// Changing the passphrase after another Mac reset the vault must not
    /// re-wrap THAT vault under this Mac's new passphrase.
    func testChangePassphraseRefusesAForeignVault() async throws {
        let a = makeMac("A")
        try await vault(a, create: "same")
        let b = makeMac("B")
        try await join(b, "same")
        try await a.engine.resetVault()
        try await a.engine.createVault(passphrase: "same")
        do { try await b.engine.changePassphrase(current: "same", new: "mine!!!!"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncEngineError, .superseded)
        }
        let c = makeMac("C")
        await c.engine.checkVault()
        try await c.engine.unlock(passphrase: "same")
    }

    // MARK: Round-3 review

    /// A join that could not apply a record (unreadable here, store busy)
    /// must still let the cloud win once it becomes readable — not upload
    /// this Mac's pre-join copy over the vault.
    func testJoinPendingRecordStillYieldsToTheCloud() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "cloud"
        try await vault(a, create: "p")
        let b = makeMac("B")
        let mine = Data("B's old hosts".utf8)
        b.app.unavailable = ["hosts"]
        b.app.refuse = ["hosts"]
        try await join(b, "p")
        // Readable again, still holding B's pre-join copy.
        b.app.unavailable = []
        b.app.refuse = []
        b.app.records["hosts"] = mine
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "cloud")
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "cloud", "the vault kept its copy")
        // And once joined, B's own edits sync normally.
        try await Task.sleep(for: .milliseconds(5))
        b.app["hosts"] = "B edits later"
        await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "B edits later")
    }

    /// Change Passphrase refused while a reset is tearing the vault down.
    func testChangePassphraseRefusedDuringReset() async throws {
        let a = makeMac("A")
        try await vault(a, create: "old")
        await drive.setDelays(read: nil, write: nil, delete: .milliseconds(100))
        let resetting = Task { try await a.engine.resetVault() }
        try await Task.sleep(for: .milliseconds(30))
        do { try await a.engine.changePassphrase(current: "old", new: "newnewnew"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncEngineError, .notReady)
        }
        try await resetting.value
        await drive.setDelays(read: nil, write: nil, delete: nil)
        let files = await drive.files
        XCTAssertTrue(files.isEmpty, "the old key file did not come back")
    }

    /// Round 5: during a join, a record readable at the snapshot that turns
    /// unreadable while the upload is in flight still yields to the cloud
    /// once readable again (it is not a known local edit).
    func testJoinRecordGoingUnreadableDuringUploadStillYields() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "cloud"
        try await vault(a, create: "p")
        let b = makeMac("B")
        b.app["hosts"] = "B pre-join"
        b.app["mine"] = "B only"          // makes B upload during the join
        await b.engine.checkVault()
        await drive.setDelays(read: nil, write: .milliseconds(150))
        // unlock starts the join sync itself (the periodic loop); do not
        // join it with another syncNow — that would add a second pass.
        try await b.engine.unlock(passphrase: "p")
        try await Task.sleep(for: .milliseconds(60))       // inside its upload
        let kept = b.app.records["hosts"]
        b.app.records["hosts"] = nil
        b.app.unavailable = ["hosts"]
        while b.engine.isSyncing { try await Task.sleep(for: .milliseconds(10)) }
        await drive.setDelays(read: nil, write: nil)
        b.app.unavailable = []
        // Readable again with what it held — unless a pass meanwhile already
        // brought the cloud's copy down over it.
        if b.app.records["hosts"] == nil { b.app.records["hosts"] = kept }
        await b.engine.syncNow()
        XCTAssertEqual(b.app["hosts"], "cloud")
        await a.engine.syncNow()
        XCTAssertEqual(a.app["hosts"], "cloud")
        XCTAssertEqual(a.app["mine"], "B only")
    }

    /// Round 7: Google revoking the grant ends like a Sign Out — no account
    /// shown, no vault key left in the Keychain.
    func testRevokedGrantCleansUpLikeSignOut() async throws {
        let a = makeMac("A")
        a.app["hosts"] = "h"
        try await vault(a, create: "p")
        await drive.setRevoked(true)
        await a.engine.syncNow()
        await drive.setRevoked(false)
        XCTAssertEqual(a.engine.phase, .signedOut)
        XCTAssertNil(a.engine.account)
        XCTAssertNil(SyncEngine.refreshToken(in: a.secrets))
        XCTAssertNil(SyncEngine.vaultKey(in: a.secrets))
        XCTAssertNotNil(a.engine.lastError)
    }
}
