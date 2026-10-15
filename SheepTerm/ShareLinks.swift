import AppKit
import Combine
import Foundation
import SheepSync

/// Share Link (ARCHITECTURE.md §21 / SHARE-LINK.md): the Mac side that talks to Sync's Google account. The crypto, the Drive calls and the
/// sender's records are in `Packages/SheepSync` (ShareService); what a group looks like on the wire is `ShareLinkPlan`.
///
/// The only extra scope is `drive.file`, asked for when the user first shares (never at sign-in). Importing needs no Drive scope: the file
/// is public ciphertext, opened with the link key + the passphrase, and the app checks the Sync sign-in address against the recipients
/// written inside (an app-side check — the real protection is link + passphrase).
@MainActor
final class ShareLinks: ObservableObject {
    static let shared = ShareLinks()

    @Published private(set) var records: [ShareRecord]
    let recordStore: ShareRecordStore
    private var timer: Timer?

    private var engine: SyncEngine { SheepTermSync.shared.engine }

    private init() {
        recordStore = ShareRecordStore(directory: BackupManager.baseDirectory, secrets: VaultSecretStore())
        records = recordStore.all()
    }

    /// The signed-in Google address, or nil.
    var account: String? { engine.account }
    var isSignedIn: Bool { engine.account != nil && engine.phase != .signedOut && engine.phase != .notConfigured && engine.phase != .signingIn }

    private func service() throws -> ShareService {
        guard isSignedIn, let service = engine.makeShareService(records: recordStore) else { throw ShareError.notSignedIn }
        return service
    }

    func refresh() { records = recordStore.all() }

    // MARK: Sender

    /// The logins a share of `group` could carry (the sheet turns the checkbox off at 0).
    func loginCount(in group: HostGroup) -> Int {
        let store = AppModel.shared.credentialStore
        return ShareLinkPlan.loginCount(group: group, credential: { store.credential(for: $0).map { ($0.name, $0.username) } },
                                        hasPassword: { Keychain.password(for: $0) != nil })
    }

    func createShare(group: HostGroup, recipients: String, includeCredentials: Bool, passphrase: String,
                     lifetime: ShareLifetime) async throws -> (record: ShareRecord, link: SharedLink) {
        _ = try service()
        try await engine.authorize(adding: GoogleOAuth.driveFileScope)
        let store = AppModel.shared.credentialStore
        let outgoing = try ShareLinkPlan.outgoing(group: group,
                                                  credential: { store.credential(for: $0).map { ($0.name, $0.username) } },
                                                  password: { Keychain.password(for: $0) })
        var credentials: ShareCredentials?
        if includeCredentials, !outgoing.logins.isEmpty {
            credentials = ShareCredentials(entries: outgoing.logins.map {
                .init(name: $0.name, username: $0.username, password: $0.password, hosts: $0.hostIDs)
            })
        }
        let request = ShareService.Request(groupDocument: outgoing.document, groupName: group.name, hostCount: outgoing.hostCount,
                                           credentials: credentials, passphrase: passphrase,
                                           recipients: [recipients], lifetime: lifetime)
        // PBKDF2 and the uploads run inside the service actor, off the main thread.
        let made = try await service().create(request)
        refresh()
        return made
    }

    func copyLink(for record: ShareRecord) -> Bool {
        guard let link = recordStore.link(for: record.id) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
        return true
    }

    func revoke(_ record: ShareRecord) async throws {
        _ = try service()
        try await engine.authorize(adding: GoogleOAuth.driveFileScope)
        try await service().revoke(record.id)
        refresh()
    }

    /// Launch and daily: Drive files past their expiry are deleted. Quiet when there is nothing to do or the user is signed out.
    func startExpiryWatch() {
        Task { try? await Task.sleep(for: .seconds(10)); await purgeExpired() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await ShareLinks.shared.purgeExpired() }
        }
    }

    func purgeExpired() async {
        let now = Date()
        guard records.contains(where: { $0.isExpired(at: now) }), isSignedIn, engine.hasGranted(GoogleOAuth.driveFileScope),
              let service = try? service() else { return }
        await service.purgeExpired()
        refresh()
    }

    // MARK: Recipient

    /// Public download, then open with the passphrase and the signed-in address. PBKDF2 runs off the main thread.
    func open(_ link: SharedLink, passphrase: String) async throws -> ShareContent {
        guard isSignedIn, let account = engine.account, let downloader = engine.makeShareDownloader() else { throw ShareError.notSignedIn }
        let blob = try await ShareService.download(link, via: downloader)
        return try await Task.detached(priority: .userInitiated) {
            try ShareService.open(blob: blob, link: link, passphrase: passphrase, account: account)
        }.value
    }

    struct Imported { var name: String; var hostCount: Int; var loginCount: Int }

    /// Adds an opened share as a NEW group. Nothing is merged into a group the user already has; a taken name becomes "Name (shared)".
    func importShare(_ content: ShareContent) throws -> Imported {
        let model = AppModel.shared
        var groups = [try ShareLinkPlan.decode(document: content.group)]
        _ = ConfigurationHygiene.sanitize(&groups, emptyGroupName: "Shared group")
        var group = groups[0]
        group.name = ShareNaming.importName(HostStore.cleanGroupName(group.name), taken: model.store.groups.map(\.name))
        group = ShareLinkPlan.landing(group)
        let existing = Set(model.credentialStore.credentials.map(\.name))
        let entries = content.credentials?.entries ?? []
        let logins = entries.map { ShareLogin(name: $0.name, username: $0.username, password: $0.password, hostIDs: $0.hosts) }
        let credentials = entries.map { entry -> Credential in
            let cleaned = ConfigurationHygiene.cleanedName(existing.contains(entry.name) ? "\(entry.name) (shared)" : entry.name)
            return Credential(name: cleaned.isEmpty ? "Unnamed Credential" : cleaned, username: entry.username)
        }
        let ids = credentials.map(\.id)
        // All or nothing: passwords first (a refusal leaves no trace), then the credentials in one save, then the group.
        guard ShareLinkPlan.storePasswords(logins, ids: ids, set: { Keychain.setPassword($0, for: $1) },
                                           remove: { _ = Keychain.deletePassword(for: $0) }) else {
            throw ShareLinkPlan.PlanError.passwordNotKept
        }
        guard model.credentialStore.addImported(credentials) else {
            ids.forEach { _ = Keychain.deletePassword(for: $0) }
            throw ShareLinkPlan.PlanError.passwordNotKept
        }
        group = ShareLinkPlan.attach(logins, credentialIDs: ids, to: group)
        let stats = model.store.applyImport(group, action: .createNew, replace: [:])
        return Imported(name: stats.groupName ?? group.name, hostCount: stats.addedHosts, loginCount: ids.count)
    }

    // MARK: sheepterm://share#…

    func handle(url: URL) {
        guard let link = SharedLink.parse(url.absoluteString) else {
            let alert = SheepAlert()
            alert.alertStyle = .warning
            alert.messageText = "That is not a SheepTerm share link"
            alert.addButton(withTitle: "OK")
            alert.sheepStyled().runModal()
            return
        }
        AppModel.shared.showImportLink(link.url)
    }
}
