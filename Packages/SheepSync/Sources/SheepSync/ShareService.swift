import Foundation

/// The sender's Drive calls. Google Drive is the real one (`GoogleDriveShareBackend`; Windows brings its own through
/// `GoogleTransport.makeShareBackend`), `MemoryShareBackend` is the tests'.
///
/// The one permission it can create is "anyone with the link can read" — the file is ciphertext that needs the link key AND the passphrase.
public protocol ShareBackend: Sendable {
    /// A new file in the app's own "SheepTerm Shares" folder. Returns the file id.
    func upload(name: String, data: Data) async throws -> String
    /// `type=anyone, role=reader, allowFileDiscovery=false`.
    func makePublic(fileID: String) async throws
    /// A file that is already gone is not an error.
    func delete(fileID: String) async throws
}

/// The recipient's side: fetch the public file. No account, no token, no Drive scope.
public protocol ShareDownloader: Sendable {
    func download(fileID: String) async throws -> Data
}

public struct ShareRecord: Codable, Equatable, Identifiable, Sendable {
    /// The Drive file id.
    public var id: String
    public var groupName: String
    public var hostCount: Int
    public var recipients: [String]
    public var created: Date
    public var expires: Date?
    public var includesCredentials: Bool

    public init(id: String, groupName: String, hostCount: Int, recipients: [String], created: Date, expires: Date?,
                includesCredentials: Bool) {
        self.id = id; self.groupName = groupName; self.hostCount = hostCount; self.recipients = recipients
        self.created = created; self.expires = expires; self.includesCredentials = includesCredentials
    }

    public func isExpired(at now: Date) -> Bool { expires.map { $0 <= now } ?? false }
}

/// The sender's list of links (`shares.json`, no secrets) and, in the secret store, each link's key — so "copy link again" works.
public final class ShareRecordStore: @unchecked Sendable {
    private let file: URL
    private let secrets: SecretStoring
    private let lock = NSLock()
    private var records: [ShareRecord]

    public init(directory: URL, secrets: SecretStoring) {
        file = directory.appendingPathComponent("shares.json")
        self.secrets = secrets
        records = []
        records = load()
    }

    private func load() -> [ShareRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let list = try? decoder.decode([ShareRecord].self, from: data) { return list }
        // Unreadable: keep it for the user to look at, start empty (these are only pointers to Drive files).
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("shares.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: file, to: aside)
        return []
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: file, options: .atomic)
    }

    public func all() -> [ShareRecord] { lock.withLock { records.sorted { $0.created > $1.created } } }

    public func add(_ record: ShareRecord, key: Data) throws {
        try lock.withLock {
            guard secrets.write("share.\(record.id)", key) else { throw ShareError.damaged("could not keep the link key") }
            records.removeAll { $0.id == record.id }
            records.append(record)
            try save()
        }
    }

    public func link(for id: String) -> SharedLink? {
        guard let key = secrets.read("share.\(id)"), key.count == 32 else { return nil }
        return SharedLink(fileID: id, key: key)
    }

    public func remove(_ id: String) throws {
        try lock.withLock {
            records.removeAll { $0.id == id }
            try save()
            secrets.delete("share.\(id)")
        }
    }
}

public struct ShareContent: Sendable {
    public var name: String
    public var hostCount: Int
    /// As written by the sender's app, unverified.
    public var sender: String
    public var recipients: [String]
    public var expires: Date?
    /// The group document, scrubbed.
    public var group: Data
    public var credentials: ShareCredentials?
}

public actor ShareService {
    public static let minimumPassphraseLength = 8

    private let backend: ShareBackend
    private let sender: String
    public nonisolated let records: ShareRecordStore
    private let now: @Sendable () -> Date

    public init(backend: ShareBackend, sender: String, records: ShareRecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.sender = sender
        self.records = records
        self.now = now
    }

    public struct Request: Sendable {
        public var groupDocument: Data
        public var groupName: String
        public var hostCount: Int
        public var credentials: ShareCredentials?
        public var passphrase: String
        public var recipients: [String]
        public var lifetime: ShareLifetime
        public init(groupDocument: Data, groupName: String, hostCount: Int, credentials: ShareCredentials?, passphrase: String,
                    recipients: [String], lifetime: ShareLifetime) {
            self.groupDocument = groupDocument; self.groupName = groupName; self.hostCount = hostCount
            self.credentials = credentials; self.passphrase = passphrase; self.recipients = recipients; self.lifetime = lifetime
        }
    }

    // MARK: Sender

    /// Encrypts, uploads, makes the file readable by link. A failure after the upload deletes the file again: a half-made share is never
    /// left in the sender's Drive.
    public func create(_ request: Request) async throws -> (record: ShareRecord, link: SharedLink) {
        let recipients = try ShareRecipients.parse(request.recipients, excluding: sender)
        guard request.hostCount > 0 else { throw ShareError.nothingToShare }
        guard request.passphrase.count >= Self.minimumPassphraseLength else { throw ShareError.passphraseTooShort }
        let created = now()
        let expires = request.lifetime.expiry(from: created)
        let credentials = request.credentials.flatMap { $0.isEmpty ? nil : $0 }
        let envelope = ShareEnvelope(created: Int(created.timeIntervalSince1970), expires: expires.map { Int($0.timeIntervalSince1970) },
                                     sender: sender, recipients: recipients, name: request.groupName, hostCount: request.hostCount,
                                     group: try ShareScrub.stripped(request.groupDocument), credentials: credentials)
        let key = try ShareCrypto.newLinkKey()
        let passphrase = request.passphrase
        // PBKDF2 (600 000 rounds) off this actor's queue.
        let blob = try await Task.detached { try ShareCrypto.seal(envelope, linkKey: key, passphrase: passphrase) }.value
        let day = ISO8601DateFormatter().string(from: created).prefix(10)
        let id = try await backend.upload(name: "SheepTerm share \(day).sheepshare", data: blob)
        do {
            try await backend.makePublic(fileID: id)
            let record = ShareRecord(id: id, groupName: request.groupName, hostCount: request.hostCount, recipients: recipients,
                                     created: created, expires: expires, includesCredentials: credentials != nil)
            try records.add(record, key: key)
            return (record, SharedLink(fileID: id, key: key))
        } catch {
            try? await backend.delete(fileID: id)
            throw error
        }
    }

    /// Deletes the Drive file (the link stops working at once) and forgets the record. Already-imported data stays where it is.
    public func revoke(_ id: String) async throws {
        try await backend.delete(fileID: id)
        try records.remove(id)
    }

    /// Run at launch and daily: every record past its expiry has its file deleted. A failed delete keeps the record for the next run.
    /// (Drive's own `expirationTime` does not apply to `anyone` permissions, so deletion — and the reader refusing an expired payload — is
    /// the whole of expiry.)
    @discardableResult
    public func purgeExpired() async -> [String] {
        var purged: [String] = []
        for record in records.all() where record.isExpired(at: now()) {
            do {
                try await backend.delete(fileID: record.id)
                try records.remove(record.id)
                purged.append(record.id)
            } catch {}
        }
        return purged
    }

    // MARK: Recipient (no account of ours is involved except the signed-in address, checked in `open`)

    /// The public ciphertext. 403/404 = the file is gone.
    public nonisolated static func download(_ link: SharedLink, via downloader: ShareDownloader) async throws -> Data {
        do {
            let data = try await downloader.download(fileID: link.fileID)
            guard data.count <= ShareCrypto.maximumBlobBytes else { throw ShareError.tooLarge }
            return data
        } catch SyncBackendError.http(let code, _) where code == 403 || code == 404 {
            throw ShareError.revoked
        }
    }

    /// CPU-heavy (PBKDF2): call off the main thread. Checks, in this order: both secrets open it, it has not expired, `account` (the
    /// Google address Sync is signed in with) is one of the recipients written inside. The last check is made by the app, not by Google —
    /// the real protection is link + passphrase.
    public nonisolated static func open(blob: Data, link: SharedLink, passphrase: String, account: String?,
                                        now: Date = Date()) throws -> ShareContent {
        guard let account, !account.isEmpty else { throw ShareError.notSignedIn }
        guard !passphrase.isEmpty else { throw ShareError.needsPassphrase }
        let envelope = try ShareCrypto.open(blob, linkKey: link.key, passphrase: passphrase)
        if let expires = envelope.expires, Date(timeIntervalSince1970: TimeInterval(expires)) <= now { throw ShareError.expired }
        guard envelope.recipients.contains(account.lowercased()) else { throw ShareError.notRecipient }
        return ShareContent(name: envelope.name, hostCount: envelope.hostCount, sender: envelope.sender, recipients: envelope.recipients,
                            expires: envelope.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            group: try ShareScrub.stripped(envelope.group), credentials: envelope.credentials)
    }
}

/// An in-memory Drive for tests: owners, a public flag per file, and an anonymous download.
public actor MemoryShareBackend: ShareBackend, ShareDownloader {
    public struct File: Equatable, Sendable {
        public var data: Data
        public var owner: String
        public var isPublic: Bool
    }
    public final class SharedStore: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: File] = [:]
        var serial = 0
        public init() {}
        public var count: Int { lock.withLock { files.count } }
        public func file(_ id: String) -> File? { lock.withLock { files[id] } }
        public func modify(_ id: String, _ change: (inout File) -> Void) { lock.withLock { if var f = files[id] { change(&f); files[id] = f } } }
    }
    public let store: SharedStore
    public let user: String
    /// Every makePublic call (the "only anyone/reader" test reads it).
    public private(set) var publicGrants: [String] = []
    public var failNextUpload = false
    public var failMakePublic = false

    public init(user: String = "", store: SharedStore = SharedStore()) {
        self.user = user
        self.store = store
    }
    public func setFailNextUpload() { failNextUpload = true }
    public func setFailMakePublic() { failMakePublic = true }

    public func upload(name: String, data: Data) async throws -> String {
        if failNextUpload { failNextUpload = false; throw SyncBackendError.http(503, "injected") }
        return store.lock.withLock {
            store.serial += 1
            let id = "mem\(String(format: "%08d", store.serial))file"
            store.files[id] = File(data: data, owner: user, isPublic: false)
            return id
        }
    }

    public func makePublic(fileID: String) async throws {
        publicGrants.append(fileID)
        if failMakePublic { throw SyncBackendError.http(400, "injected") }
        guard let file = store.file(fileID), file.owner == user else { throw SyncBackendError.http(404, "not found") }
        store.modify(fileID) { $0.isPublic = true }
    }

    public func download(fileID: String) async throws -> Data {
        guard let file = store.file(fileID), file.isPublic else { throw SyncBackendError.http(404, "not found") }
        return file.data
    }

    public func delete(fileID: String) async throws {
        guard let file = store.file(fileID) else { return }
        guard file.owner == user else { throw SyncBackendError.http(403, "forbidden") }
        store.lock.withLock { store.files[fileID] = nil }
    }
}
