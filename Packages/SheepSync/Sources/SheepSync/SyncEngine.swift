import CryptoKit
import Foundation
import Network
import Observation

/// Everything an app tells SheepSync about itself.
public struct SyncConfiguration: Sendable {
    /// Shown in the browser page after sign-in; also names the data file.
    public var appName: String
    public var google: GoogleClient
    /// The app's Keychain service. SheepSync's own items are `sheepsync.*`.
    public var keychainService: String
    /// Where `sync-state.json` lives (the app's Application Support folder).
    public var stateDirectory: URL
    /// Human-readable, for stamps: "MacBook Air".
    public var deviceName: String
    /// Shared by every Sheep app on purpose: one passphrase for the family.
    public var keyFileName: String
    public var dataFileName: String
    /// Quiet time after a local change before syncing it.
    public var debounce: Duration
    /// How often a signed-in, unlocked Mac checks the cloud on its own.
    public var interval: Duration

    public init(appName: String, google: GoogleClient, keychainService: String, stateDirectory: URL,
                deviceName: String, keyFileName: String = "sheepsync-vault-key.json",
                dataFileName: String? = nil, debounce: Duration = .seconds(3),
                interval: Duration = .seconds(300)) {
        self.appName = appName
        self.google = google
        self.keychainService = keychainService
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.keyFileName = keyFileName
        self.dataFileName = dataFileName ?? "\(appName.lowercased())-sync.sealed"
        self.debounce = debounce
        self.interval = interval
    }
}

/// The app side: records out, records in. Called on the main actor.
@MainActor
public protocol SyncDataSource: AnyObject {
    /// The app's records as they are now.
    func syncSnapshot() -> SyncSnapshot
    /// Make these changes locally — a value to write, nil to delete — and
    /// say which could NOT be applied (they are retried on the next sync).
    /// `firstJoin` is true on this Mac's first sync with a vault: the moment
    /// to set the current data aside, because the cloud's copy is about to
    /// replace it.
    func syncApply(_ changes: [String: Data?], firstJoin: Bool) -> SyncApplyResult
}

public struct SyncApplyResult: Equatable, Sendable {
    public var failed: Set<String>
    /// The app refused the WHOLE join (it could not set its data aside).
    /// Only this keeps the Mac in join mode — an ordinary failed record
    /// must not, or every later sync would be another join.
    public var refusedJoin: Bool

    public init(failed: Set<String> = [], refusedJoin: Bool = false) {
        self.failed = failed
        self.refusedJoin = refusedJoin
    }
}

/// Where secrets are kept; the Keychain in the app, memory in tests.
public protocol SecretStoring: Sendable {
    func read(_ account: String) -> Data?
    @discardableResult func write(_ account: String, _ value: Data) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
}

extension SecretStore: SecretStoring {}

public enum SyncPhase: Equatable, Sendable {
    /// This build has no Google client configured.
    case notConfigured
    case signedOut
    case signingIn
    /// Signed in; looking for a vault in the cloud.
    case checkingVault
    /// Signed in, no vault in this account yet: choose a passphrase.
    case needsNewPassphrase
    /// Signed in, a vault exists: enter its passphrase on this Mac.
    case needsPassphrase
    case ready
}

public enum SyncEngineError: Error, Equatable, LocalizedError {
    case vaultAlreadyExists
    case noVault
    case notReady
    /// Sign-out, reset or another sign-in happened while this was running;
    /// its result belongs to a vault that is no longer this Mac's.
    case superseded
    case stateNotSaved(String)

    public var errorDescription: String? {
        switch self {
        case .vaultAlreadyExists: return "This Google account already has a vault — enter its passphrase instead."
        case .noVault: return "There is no vault in this Google account."
        case .notReady: return "Sync is not set up on this Mac."
        case .superseded: return "Cancelled — sync was signed out or reset meanwhile."
        case .stateNotSaved(let why): return "Sync could not save its state on this Mac (\(why))."
        }
    }
}

/// This Mac's memory of the sync, in `sync-state.json`. No secrets: the
/// shadow holds stamps and keyed digests only.
struct SyncLocalState: Codable, Equatable {
    var account: String?
    var picture: URL?
    /// Which vault the Keychain key and the shadow belong to.
    var keyID: String?
    /// nil = this Mac has not completed a sync with the vault yet.
    var shadow: [String: ShadowEntry]?
    /// Records the JOIN could not apply yet (unreadable here, store busy).
    /// Until each lands, its local copy still yields to the cloud's — it
    /// must not be uploaded over the vault the moment it becomes readable.
    var joinPending: Set<String>?
    var lastSync: Date?
    /// Tie-breaker in stamps; stable per Mac.
    var device: String
}

@MainActor
@Observable
public final class SyncEngine {
    public private(set) var phase: SyncPhase
    /// The signed-in Google address.
    public private(set) var account: String?
    /// The account's Google profile picture (https), when it has one.
    public private(set) var accountPicture: URL?
    public private(set) var isSyncing = false
    /// False while the Mac has no network path (Wi-Fi off, cable out). No
    /// sync is attempted then — and none is reported as failed — and one
    /// runs as soon as the path comes back.
    public private(set) var isOnline = true
    public private(set) var lastSync: Date?
    /// The last failure, in words for the user; cleared by a good sync.
    public private(set) var lastError: String?

    @ObservationIgnored public weak var dataSource: SyncDataSource?
    /// Opens the Google sign-in page (the app passes NSWorkspace.open).
    @ObservationIgnored public var openURL: @MainActor (URL) -> Void = { _ in }

    @ObservationIgnored private let config: SyncConfiguration
    @ObservationIgnored private let secrets: SecretStoring
    @ObservationIgnored private let makeBackend: @MainActor (GoogleAccount) -> SyncBackend
    @ObservationIgnored private var backend: SyncBackend?
    @ObservationIgnored private var googleAccount: GoogleAccount?
    @ObservationIgnored private var sealer: VaultSealer?
    @ObservationIgnored private var state: SyncLocalState
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var loopback: LoopbackReceiver?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var currentRun: Task<Void, Never>?
    @ObservationIgnored private var cachedKeyFile: VaultKeyFile?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Bumped by everything that changes WHICH vault/account this Mac is on
    /// (sign-in, sign-out, reset, adopting a key). Work that awaited across
    /// such a change must not act on its result — see `ensure(_:)`.
    @ObservationIgnored private var epoch = 0
    /// What the cloud held at the last sync, by file version: when neither
    /// file changed since, a sync downloads nothing (one small listing).
    private struct CloudCache {
        var keyVersion: String?
        var keyFile: VaultKeyFile?
        var dataVersion: String?
        var remote: [String: SyncRecord]?
    }
    @ObservationIgnored private var cache = CloudCache()
    /// Set while sign-out or reset is tearing the vault down: no new sync
    /// may start in that window (the phase still reads .ready until the
    /// teardown's awaits are done).
    @ObservationIgnored private var tearingDown = false

    /// The data file starts with this and the vault's key id, OUTSIDE the
    /// ciphertext: a file sealed under another vault's key (a Mac that
    /// wrote just as the vault was reset elsewhere) is then recognisable as
    /// debris and replaced, instead of failing to open forever.
    static let dataMagic = Data("SSD1".utf8)

    /// ONE Keychain item for both secrets (the refresh token and the vault
    /// key). Two items meant two "allow access" prompts whenever the app's
    /// signature changed (every ad-hoc-signed update) — one is the floor.
    nonisolated static let sessionAccount = "session"

    private struct Session: Codable {
        var refreshToken: String?
        var vaultKey: Data?
    }

    nonisolated private static func session(in secrets: SecretStoring) -> Session {
        secrets.read(sessionAccount).flatMap { try? JSONDecoder().decode(Session.self, from: $0) } ?? Session()
    }

    @discardableResult
    nonisolated private static func updateSession(in secrets: SecretStoring, _ change: (inout Session) -> Void) -> Bool {
        var value = session(in: secrets)
        change(&value)
        if value.refreshToken == nil, value.vaultKey == nil { return secrets.delete(sessionAccount) }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return secrets.write(sessionAccount, data)
    }

    nonisolated public static func refreshToken(in secrets: SecretStoring) -> String? { session(in: secrets).refreshToken }
    nonisolated public static func vaultKey(in secrets: SecretStoring) -> Data? { session(in: secrets).vaultKey }
    @discardableResult
    nonisolated public static func setRefreshToken(_ token: String?, in secrets: SecretStoring) -> Bool {
        updateSession(in: secrets) { $0.refreshToken = token }
    }
    @discardableResult
    nonisolated static func setVaultKey(_ key: Data?, in secrets: SecretStoring) -> Bool {
        updateSession(in: secrets) { $0.vaultKey = key }
    }

    public convenience init(configuration: SyncConfiguration) {
        self.init(configuration: configuration,
                  secrets: SecretStore(service: configuration.keychainService),
                  makeBackend: { GoogleDriveBackend(account: $0) })
    }

    /// Tests: any secret store and any backend.
    public init(configuration: SyncConfiguration, secrets: SecretStoring,
                makeBackend: @escaping @MainActor (GoogleAccount) -> SyncBackend) {
        config = configuration
        self.secrets = secrets
        self.makeBackend = makeBackend
        state = Self.loadState(configuration)
        lastSync = state.lastSync
        phase = configuration.google.isConfigured ? .signedOut : .notConfigured
        guard configuration.google.isConfigured,
              let token = Self.refreshToken(in: secrets)
        else { return }
        // Shown only while signed in: the state file also remembers the last
        // account after a sign-out (see `signOut`).
        account = state.account
        accountPicture = state.picture
        attach(refreshToken: token)
        if let raw = Self.vaultKey(in: secrets), raw.count == 32,
           VaultKeyFile.keyID(of: SymmetricKey(data: raw)) == state.keyID {
            sealer = VaultSealer(vaultKey: SymmetricKey(data: raw))
            phase = .ready
        } else {
            phase = .checkingVault
        }
    }

    /// Call once the app is up: resumes where the last launch left off.
    public func start() {
        watchNetwork()
        switch phase {
        case .ready: becameReady()
        case .checkingVault: Task { await checkVault() }
        default: break
        }
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "SheepSync.path"))
        pathMonitor = monitor
    }

    private func networkChanged(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        guard online else { return }
        switch phase {
        case .ready: Task { await syncNow() }
        case .checkingVault: Task { await checkVault() }
        default: break
        }
    }

    // MARK: Sign-in

    public func signIn() async {
        guard phase == .signedOut || phase == .notConfigured, config.google.isConfigured else { return }
        phase = .signingIn
        lastError = nil
        epoch &+= 1
        let started = epoch
        do {
            let receiver = try LoopbackReceiver(appName: config.appName)
            loopback = receiver
            let pkce = try GoogleOAuth.PKCE.make()
            let expected = try GoogleOAuth.makeState()
            let redirect = try await receiver.start(expectedState: expected)
            openURL(GoogleOAuth.authorizationURL(client: config.google, redirectURI: redirect,
                                                 pkce: pkce, state: expected))
            let parameters = try await receiver.waitForRedirect(timeout: 300)
            loopback = nil
            let code = try GoogleOAuth.code(from: parameters, expectedState: expected)
            let (data, response) = try await URLSession.shared.data(
                for: GoogleOAuth.codeExchangeRequest(client: config.google, code: code, pkce: pkce,
                                                     redirectURI: redirect))
            let answer = try GoogleOAuth.parseTokenResponse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            try ensure(started)
            guard let refresh = answer.refreshToken else {
                throw GoogleOAuth.OAuthError.server("Google did not grant offline access")
            }
            guard Self.setRefreshToken(refresh, in: secrets) else {
                throw GoogleOAuth.OAuthError.server("the Keychain refused to store the sign-in")
            }
            if state.account != answer.email {
                // Another Google account is another vault: nothing this Mac
                // remembers about the previous one applies.
                forgetVault()
            }
            state.account = answer.email
            state.picture = answer.picture
            account = answer.email
            accountPicture = answer.picture
            saveState()
            attach(refreshToken: refresh)
            phase = .checkingVault
            await checkVault()
        } catch {
            loopback?.cancel()
            loopback = nil
            guard epoch == started else { return }
            phase = .signedOut
            if (error as? GoogleOAuth.OAuthError) != .cancelled { lastError = describe(error) }
        }
    }

    public func cancelSignIn() { loopback?.cancel() }

    /// Forgets the sign-in and the vault key on this Mac. The app's data and
    /// the cloud copy are left alone — and so is what this Mac remembers of
    /// the last sync (account, vault id, shadow): signing back in to the same
    /// account and vault is then an ordinary sync, where edits made while
    /// signed out win as the newer ones, not a join that would let the
    /// cloud's older copies replace them. Another account, or a vault reset
    /// meanwhile, still starts over (`signIn` / `adopt`).
    public func signOut() async {
        loopback?.cancel()
        await supersede()
        defer { tearingDown = false }
        if let googleAccount { await googleAccount.revoke() }
        secrets.delete(Self.sessionAccount)
        sealer = nil
        cachedKeyFile = nil
        cache = CloudCache()
        googleAccount = nil
        backend = nil
        account = nil
        accountPicture = nil
        saveState()
        lastError = nil
        phase = .signedOut
    }

    private func attach(refreshToken: String) {
        let secrets = self.secrets
        let account = GoogleAccount(client: config.google, refreshToken: refreshToken) { rotated in
            SyncEngine.setRefreshToken(rotated, in: secrets)
        }
        googleAccount = account
        backend = makeBackend(account)
    }

    private func ensure(_ started: Int) throws {
        if epoch != started { throw SyncEngineError.superseded }
    }

    /// Stops the sync in flight (if any) before the vault changes under it:
    /// the run notices the new epoch at its next step, and a write it has
    /// already sent lands BEFORE the caller deletes or forgets anything.
    private func supersede() async {
        epoch &+= 1
        tearingDown = true
        stopTimers()
        if let run = currentRun { await run.value }
    }

    // MARK: Vault

    public func checkVault() async {
        guard let backend else { phase = .signedOut; return }
        phase = .checkingVault
        let started = epoch
        do {
            let file = try await readKeyFile(backend)
            // A late answer (two checks in flight, or the user unlocked /
            // signed out meanwhile) must not move the phase backwards.
            guard epoch == started, phase == .checkingVault else { return }
            cachedKeyFile = file
            lastError = nil
            phase = file == nil ? .needsNewPassphrase : .needsPassphrase
        } catch {
            guard epoch == started, phase == .checkingVault else { return }
            fail(error)
            if phase == .checkingVault {
                // Offline at launch: try again later rather than leaving the
                // panel stuck on "checking".
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled, self.phase == .checkingVault else { return }
                    await self.checkVault()
                }
            }
        }
    }

    /// First Mac: a new vault under `passphrase`.
    public func createVault(passphrase: String) async throws {
        guard let backend, phase != .ready else { throw SyncEngineError.notReady }
        let started = epoch
        if try await readKeyFile(backend) != nil {
            try ensure(started)
            phase = .needsPassphrase
            throw SyncEngineError.vaultAlreadyExists
        }
        let (file, key) = try await Task.detached { try VaultKeyFile.create(passphrase: passphrase) }.value
        try ensure(started)
        // A data file without a key file is debris (a reset that died
        // half-way, an old vault): it can never be opened by the new key.
        try await backend.delete(config.dataFileName)
        try ensure(started)
        try await backend.write(config.keyFileName, try Self.encoder.encode(file))
        try ensure(started)
        try adopt(key: key, keyID: file.keyID, createdHere: true)
    }

    /// Another Mac: open the existing vault.
    public func unlock(passphrase: String) async throws {
        guard let backend else { throw SyncEngineError.notReady }
        let started = epoch
        guard let file = try await readKeyFile(backend) else {
            try ensure(started)
            phase = .needsNewPassphrase
            throw SyncEngineError.noVault
        }
        let key = try await Task.detached { try file.unwrap(passphrase: passphrase) }.value
        // Signed out (or reset) while the passphrase was being checked: do
        // not write the key back or claim "ready" with no backend.
        try ensure(started)
        try adopt(key: key, keyID: file.keyID, createdHere: false)
    }

    public func changePassphrase(current: String, new: String) async throws {
        guard let backend, phase == .ready, !tearingDown else { throw SyncEngineError.notReady }
        let started = epoch
        guard let file = try await readKeyFile(backend) else { throw SyncEngineError.noVault }
        try ensure(started)
        // Reset elsewhere meanwhile: that is not OUR vault to re-wrap.
        guard file.keyID == state.keyID else { throw SyncEngineError.superseded }
        let rewrapped = try await Task.detached { () throws -> VaultKeyFile in
            let key = try file.unwrap(passphrase: current)
            return try file.rewrapped(key, newPassphrase: new)
        }.value
        try ensure(started)
        try await backend.write(config.keyFileName, try Self.encoder.encode(rewrapped))
    }

    /// The forgotten-passphrase way out: deletes the vault in the cloud. This
    /// Mac's data stays and becomes the new vault's content once a new
    /// passphrase is chosen; other Macs have to unlock again.
    public func resetVault() async throws {
        guard let backend else { throw SyncEngineError.notReady }
        await supersede()
        defer { tearingDown = false }
        do {
            try await backend.delete(config.dataFileName)
            try await backend.delete(config.keyFileName)
        } catch {
            // Nothing (or only the data file) was deleted: carry on with the
            // vault this Mac still holds.
            if phase == .ready { becameReady() }
            throw error
        }
        forgetVault()
        // The new vault starts from this Mac's data, so the first sync must
        // upload it, not treat it as a join.
        state.shadow = [:]
        saveState()
        // Whatever the old vault said ("could not be read" …) is over.
        lastError = nil
        phase = .needsNewPassphrase
    }

    private func adopt(key: SymmetricKey, keyID: String, createdHere: Bool) throws {
        guard backend != nil else { throw SyncEngineError.notReady }
        guard Self.setVaultKey(key.withUnsafeBytes { Data($0) }, in: secrets) else {
            throw GoogleOAuth.OAuthError.server("the Keychain refused to store the vault key")
        }
        epoch &+= 1
        cache = CloudCache()
        if state.keyID != keyID {
            // A vault this Mac never synced with: JOIN it (cloud wins). Only
            // a vault this Mac just created after its own reset starts from
            // this Mac's data (shadow [:] = "everything here is current").
            // Unlocking a vault another Mac created meanwhile is a join.
            state.shadow = createdHere && state.shadow == [:] ? [:] : nil
        }
        state.keyID = keyID
        saveState()
        sealer = VaultSealer(vaultKey: key)
        lastError = nil
        phase = .ready
        becameReady()
    }

    private func forgetVault() {
        cache = CloudCache()
        Self.setVaultKey(nil, in: secrets)
        sealer = nil
        cachedKeyFile = nil
        state.keyID = nil
        state.shadow = nil
        state.joinPending = nil
        state.lastSync = nil
        lastSync = nil
        saveState()
    }

    private func readKeyFile(_ backend: SyncBackend) async throws -> VaultKeyFile? {
        guard let data = try await backend.read(config.keyFileName) else { return nil }
        let file = try Self.decoder.decode(VaultKeyFile.self, from: data)
        guard file.format <= VaultKeyFile.currentFormat else {
            throw VaultCryptoError.unsupportedFormat(file.format)
        }
        return file
    }

    // MARK: Syncing

    /// A local change happened: sync after the debounce.
    public func noteLocalChange() {
        guard phase == .ready else { return }
        pending?.cancel()
        pending = Task { [weak self, debounce = config.debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func becameReady() {
        periodic?.cancel()
        periodic = Task { [weak self, interval = config.interval] in
            while !Task.isCancelled {
                guard let engine = self else { return }
                await engine.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopTimers() {
        pending?.cancel()
        periodic?.cancel()
        pending = nil
        periodic = nil
    }

    /// Syncs now. If a sync is already running, it runs once more after
    /// the current pass (to pick up whatever changed meanwhile) and this
    /// call returns when that is done.
    public func syncNow() async {
        if let running = currentRun {
            syncAgain = true
            await running.value
            return
        }
        guard phase == .ready, isOnline, !tearingDown, let backend, let sealer, let dataSource else { return }
        let run = Task { @MainActor in
            isSyncing = true
            // Cleared by the run itself, not by whoever started it: a caller
            // that joined this run can return (and call again) before the
            // starter resumes, and must not find a finished run "in progress".
            defer { isSyncing = false; currentRun = nil }
            var followedUp = false
            repeat {
                syncAgain = false
                do {
                    let outcome = try await syncOnce(backend: backend, sealer: sealer, dataSource: dataSource)
                    lastError = outcome.warning
                    if outcome.applied, !followedUp {
                        followedUp = true
                        syncAgain = true
                    }
                } catch {
                    fail(error)
                    return
                }
            } while syncAgain && phase == .ready
        }
        currentRun = run
        await run.value
    }

    /// A warning for the user (nil when all went through), and whether
    /// anything was applied here — then one more pass runs at once, so what
    /// the apply changed locally (a credential removed with its password)
    /// reaches the cloud now, not in five minutes.
    private func syncOnce(backend: SyncBackend, sealer: VaultSealer,
                          dataSource: SyncDataSource) async throws -> (warning: String?, applied: Bool) {
        // The vault must still be the one our key opens: a reset on another
        // Mac replaces the key file, and writing with the old key would put
        // data in the cloud nobody else can read.
        let started = epoch
        let keyName = config.keyFileName, dataName = config.dataFileName
        let versions = try await backend.versions([keyName, dataName])
        try ensure(started)
        let keyFile: VaultKeyFile?
        if let version = versions[keyName], version == cache.keyVersion, let known = cache.keyFile {
            keyFile = known
        } else {
            keyFile = try await readKeyFile(backend)
            try ensure(started)
            cache.keyVersion = versions[keyName]
            cache.keyFile = keyFile
        }
        guard let file = keyFile, file.keyID == state.keyID else {
            forgetVault()
            stopTimers()
            epoch &+= 1
            phase = .checkingVault
            await checkVault()
            return ("The vault was reset on another Mac — enter the new passphrase.", false)
        }
        // The key id is part of the context: data sealed under another vault's
        // key can never be mistaken for this vault's.
        let context = "sheepsync/data/v1/\(config.dataFileName)/\(file.keyID)"
        var remote: [String: SyncRecord] = [:]
        var debris = false
        if let version = versions[dataName], version == cache.dataVersion, let known = cache.remote {
            remote = known
        } else if versions[dataName] != nil {
            let sealedData = try await backend.read(dataName)
            try ensure(started)
            if let blob = sealedData {
                let header = Self.dataMagic + Data(file.keyID.utf8)
                let foreign = blob.count >= header.count && blob.prefix(Self.dataMagic.count) == Self.dataMagic
                    && blob.prefix(header.count) != header
                if foreign {
                    // Sealed under another vault's key, beside OUR key file:
                    // debris of a reset race. Nothing in it is readable by
                    // anyone on this vault — replace it.
                    debris = true
                } else {
                    guard blob.prefix(header.count) == header else {
                        throw VaultCryptoError.damaged("data file header")
                    }
                    let opened = try sealer.open(blob.dropFirst(header.count), context: context)
                    let document = try Self.decoder.decode(SyncDocument.self, from: opened)
                    guard document.format <= SyncDocument.currentFormat else {
                        throw VaultCryptoError.unsupportedFormat(document.format)
                    }
                    remote = document.byID
                }
            }
            if !debris {
                cache.dataVersion = versions[dataName]
                cache.remote = remote
            }
        }
        let oldShadow = state.shadow
        let snapshot = dataSource.syncSnapshot()
        let pending = state.joinPending ?? []
        let plan = SyncMerge.plan(snapshot: snapshot, shadow: oldShadow, remote: remote,
                                  now: Int64(Date().timeIntervalSince1970 * 1000), device: state.device,
                                  joining: pending, digest: sealer.digest)
        var apply = plan.apply
        var shadow = plan.shadow
        var droppedDuringJoin: Set<String> = []
        if plan.needsUpload || debris {
            let plain = try Self.encoder.encode(SyncDocument(records: Array(plan.merged.values)))
            let blob = Self.dataMagic + Data(file.keyID.utf8) + (try sealer.seal(plain, context: context))
            try await backend.write(config.dataFileName, blob)
            try ensure(started)
            // Our write has a version we did not list; another Mac may also
            // write in between. Download once next time rather than guess.
            cache.dataVersion = nil
            cache.remote = nil
            // The upload awaited: anything the user changed meanwhile must
            // not be overwritten by the cloud's copy. Leave such a record to
            // the next sync, which sees it as a local edit.
            if !apply.isEmpty {
                let now = dataSource.syncSnapshot()
                for id in apply.keys where now.records[id] != snapshot.records[id] {
                    apply[id] = nil
                    shadow[id] = oldShadow?[id]
                    // Unreadable at the snapshot, so whatever it holds now
                    // is NOT a known local edit: during a join it still
                    // yields to the cloud next time.
                    if oldShadow == nil || pending.contains(id), snapshot.isUnavailable(id) || now.isUnavailable(id) {
                        droppedDuringJoin.insert(id)
                    }
                }
            }
        }
        var warning: String?
        var applied = false
        var lastFailed: Set<String> = []
        if !apply.isEmpty {
            let result = dataSource.syncApply(apply, firstJoin: oldShadow == nil)
            let failed = result.failed
            lastFailed = failed
            applied = true
            // A change that did not land: remember the cloud's stamp against
            // what is REALLY here, so the next sync sees "unchanged here,
            // cloud's copy wins" and tries again — instead of "changed here
            // just now", which would push the stale local value over it.
            for id in failed {
                guard let entry = shadow[id] else { continue }
                if snapshot.isUnavailable(id) {
                    // Unreadable here AND not applied: we know nothing new
                    // about it. Recording the cloud's tombstone as ours would
                    // make the record, once readable, look like a fresh
                    // re-creation and bring it back everywhere.
                    shadow[id] = oldShadow?[id]
                    continue
                }
                let current = snapshot.records[id]
                shadow[id] = ShadowEntry(stamp: entry.stamp, deleted: current == nil,
                                         digest: current.map { sealer.digest(id: id, payload: $0) })
            }
            if !failed.isEmpty {
                warning = "\(failed.count) item\(failed.count == 1 ? "" : "s") from the cloud could not be applied on this Mac; will retry."
            }
            if oldShadow == nil, result.refusedJoin {
                // Still joining: the app refuses to apply a join it could
                // not set the old configuration aside for, and that promise
                // must hold on the NEXT sync too — which it only does while
                // this Mac stays in join mode.
                state.lastSync = Date()
                lastSync = state.lastSync
                state.shadow = nil
                try saveStateOrThrow()
                return (warning, false)
            }
        }
        // Join bookkeeping: what the join (or a still-pending part of it)
        // could not apply stays pending; what landed, or what the cloud no
        // longer has, is done.
        let failedNow = applied ? lastFailed : []
        var stillPending = pending.filter { remote[$0] != nil && (failedNow.contains($0) || apply[$0] == nil && snapshot.isUnavailable($0)) }
        if oldShadow == nil { stillPending.formUnion(failedNow) }
        stillPending.formUnion(droppedDuringJoin.filter { remote[$0] != nil })
        for id in stillPending { shadow[id] = nil }
        state.joinPending = stillPending.isEmpty ? nil : stillPending
        state.shadow = shadow
        state.lastSync = Date()
        lastSync = state.lastSync
        try saveStateOrThrow()
        return (warning, applied)
    }

    private func fail(_ error: Error) {
        if case SyncEngineError.superseded = error { return }
        if case SyncBackendError.notAuthorized = error {
            // Google revoked or expired the grant: the same as Sign Out,
            // minus the revoke call (nothing left to revoke). The state file
            // is kept, as Sign Out keeps it.
            secrets.delete(Self.sessionAccount)
            sealer = nil
            cachedKeyFile = nil
            cache = CloudCache()
            googleAccount = nil
            backend = nil
            account = nil
            accountPicture = nil
            stopTimers()
            phase = .signedOut
        }
        lastError = describe(error)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case VaultCryptoError.wrongPassphrase: return "That passphrase does not open this vault."
        case VaultCryptoError.damaged("data file header"):
            // Only a pre-release test build ever wrote a data file without
            // the header: say what to do, not just what failed.
            return "The synced data was written by an older test build. Use Reset Sync… to start it again from this Mac. Nothing was changed."
        case VaultCryptoError.damaged(let what): return "The vault in the cloud could not be read (\(what)). Nothing was changed."
        case VaultCryptoError.unsupportedFormat: return "The vault was written by a newer version — update the app."
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: State file

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func stateURL(_ config: SyncConfiguration) -> URL {
        config.stateDirectory.appendingPathComponent("sync-state.json")
    }

    private static func loadState(_ config: SyncConfiguration) -> SyncLocalState {
        if let data = try? Data(contentsOf: stateURL(config)),
           let state = try? decoder.decode(SyncLocalState.self, from: data) {
            return state
        }
        // Missing or unreadable: start as a Mac that never synced. That is
        // the safe reading — the next sync JOINS the vault (cloud wins)
        // instead of treating every local record as a fresh edit.
        let suffix = UUID().uuidString.prefix(8)
        return SyncLocalState(device: "\(config.deviceName)#\(suffix)")
    }

    private func saveState() {
        try? saveStateOrThrow()
    }

    /// The sync path's save: a shadow that did not land would make values
    /// just applied from the cloud look like fresh local edits next time,
    /// so the failure is reported instead of swallowed.
    private func saveStateOrThrow() throws {
        do {
            try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: Self.stateURL(config), options: .atomic)
        } catch {
            throw SyncEngineError.stateNotSaved(error.localizedDescription)
        }
    }
}
