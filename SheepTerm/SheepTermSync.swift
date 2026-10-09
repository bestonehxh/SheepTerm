import AppKit
import Combine
import Foundation
import SheepSync

/// SheepTerm's side of SheepSync (Settings → Sync): which records go to the
/// cloud, and how a record that comes back is written here. Everything about
/// Google, the vault and merging lives in `Packages/SheepSync`.
///
/// Records (ids are part of the vault format — never rename one):
/// - one per group, host, credential and snippet, plus an order record per
///   file (`SyncRecordCodec`) — so edits to different entries on two Macs
///   both survive. Changes from the cloud are put back together into the
///   file, which then goes through the SAME checks a backup restore does
///   (`BackupManager.validate` + `sanitize`: decodes, no secret fields in
///   credentials, names cleaned) before it is written.
/// - `password:<credential uuid>` — the Keychain password of a credential.
/// - `setting:<key>` — the settings Backup carries, minus the ones that
///   belong to one Mac's screen (`localOnlySettings`).
///
/// Not synced, on purpose: recents (this Mac's history), history.json,
/// session logs, ~/.ssh/known_hosts (OpenSSH's file, shared with other tools).
///
/// Off until the user signs in: the engine makes no network call before that.
@MainActor
final class SheepTermSync: SyncDataSource {
    static let shared = SheepTermSync()

    let engine: SyncEngine
    /// Settings that describe this Mac's window, not the user's preferences.
    static let localOnlySettings: Set<String> = [
        "collapsedGroups", "collapsedHostSections", "sidebarWidth", "TSMLanguageIndicatorEnabled",
        // A RAM trade for THIS machine (CLAUDE.md), not a preference.
        "scrollbackLines",
        // A security opt-in: turning it on for one Mac must not turn it on
        // for every Mac.
        "allowOSC52ClipboardWrite",
    ]

    private var subscriptions = Set<AnyCancellable>()
    /// True while a cloud change is being written here, so the stores'
    /// own change notifications do not schedule a pointless sync of it.
    private var applying = false
    private var lastActivationSync = Date.distantPast
    /// The synced settings as last seen, so a defaults change that is NOT
    /// one of them (a window frame, the sidebar width) schedules nothing.
    private var lastSettings: [String: Data] = [:]

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        // A Desktop-app client cannot sign in without its secret (Google
        // refuses the code exchange), and a public clone builds without
        // Secrets.xcconfig: then Sync is "not available", not a Sign In
        // button that fails half-way.
        let secret = (info["SheepSyncGoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let id = SyncPolicy.usableClientID(id: info["SheepSyncGoogleClientID"] as? String ?? "", secret: secret)
        let client = GoogleClient(clientID: id, clientSecret: secret)
        engine = SyncEngine(configuration: SyncConfiguration(
            appName: "SheepTerm", google: client, keychainService: "Bestchaan.SheepTerm",
            stateDirectory: BackupManager.baseDirectory, deviceName: ShareCodec.deviceName))
        engine.openURL = { NSWorkspace.shared.open($0) }
        engine.dataSource = self
    }

    /// From `applicationDidFinishLaunching`.
    func start() {
        let model = AppModel.shared
        let changed: () -> Void = { [weak self] in
            guard let self, !self.applying else { return }
            self.engine.noteLocalChange()
        }
        model.store.$groups.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
        model.credentialStore.$credentials.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
        model.snippetStore.$snippets.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
        lastSettings = Self.syncedSettings()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.applying else { return }
                let now = Self.syncedSettings()
                guard now != self.lastSettings else { return }
                self.lastSettings = now
                self.engine.noteLocalChange()
            }
            .store(in: &subscriptions)
        // Coming back to the app is when another Mac's edits are most likely
        // waiting — at most once a minute.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastActivationSync) > 60 else { return }
                self.lastActivationSync = Date()
                Task { await self.engine.syncNow() }
            }
            .store(in: &subscriptions)
        engine.start()
    }

    // MARK: Records out

    func syncSnapshot() -> SyncSnapshot {
        var records: [String: Data] = [:]
        var unavailable: Set<String> = []
        var unavailablePrefixes: [String] = []
        var wantCloud: [String] = []
        for family in SyncRecordCodec.families {
            // Quarantined at launch, or no file and an empty store: what is
            // here is not the user's data — take ALL of the family from the
            // cloud. Missing under a full store, unreadable, holding unsaved
            // changes, or not splittable (two entries on one id): NEVER read
            // as deletions, which would delete every entry everywhere.
            let url = BackupManager.baseDirectory.appendingPathComponent(family.file)
            let data = try? Data(contentsOf: url)
            let split = data.flatMap { storeMatchesDisk(family.file, $0) ? try? SyncRecordCodec.decompose($0, as: family) : nil }
            switch SyncPolicy.familyRead(quarantined: quarantined(family.file),
                                         fileExists: FileManager.default.fileExists(atPath: url.path),
                                         storeEmpty: storeIsEmpty(family.file), readableAndSaved: split != nil) {
            case .wantCloud: wantCloud += family.prefixes
            case .unavailable: unavailablePrefixes += family.prefixes
            case .records: records.merge(split ?? [:]) { a, _ in a }
            }
        }
        let credentials = AppModel.shared.credentialStore
        let passwords = SyncPolicy.passwordRecords(
            listTrusted: credentials.isTrusted, listFileReadable: records[SyncRecordCodec.credentials.order] != nil,
            credentialIDs: credentials.credentials.map(\.id), password: { Keychain.passwordWithoutPrompt(for: $0) })
        records.merge(passwords.records) { a, _ in a }
        unavailable.formUnion(passwords.unavailable)
        unavailablePrefixes += passwords.unavailablePrefixes
        for (key, data) in Self.syncedSettings() {
            records["setting:\(key)"] = data
        }
        for key in Self.syncedSettingKeys where records["setting:\(key)"] == nil {
            unavailable.insert("setting:\(key)")
        }
        return SyncSnapshot(records: records, unavailable: unavailable, unavailablePrefixes: unavailablePrefixes,
                            wantCloudPrefixes: wantCloud)
    }

    private func storeIsEmpty(_ name: String) -> Bool {
        let model = AppModel.shared
        switch name {
        case "hosts.json": return model.store.groups.isEmpty
        case "credentials.json": return model.credentialStore.credentials.isEmpty
        case "snippets.json": return model.snippetStore.snippets.isEmpty
        default: return false
        }
    }

    private func quarantined(_ name: String) -> Bool {
        let model = AppModel.shared
        switch name {
        case "hosts.json": return model.store.hostsQuarantined
        case "credentials.json": return !model.credentialStore.isTrusted
        case "snippets.json": return model.snippetStore.quarantinedSinceLoad
        default: return false
        }
    }

    static var syncedSettingKeys: [String] {
        BackupManager.settingKeys.filter { !localOnlySettings.contains($0) }
    }

    /// The synced settings as record bytes (also what the defaults observer
    /// compares, so only a change to one of THESE schedules a sync).
    static func syncedSettings() -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let settings = BackupManager.currentSettings()
        var out: [String: Data] = [:]
        for key in syncedSettingKeys {
            if let value = settings[key], let data = try? encoder.encode(value) { out[key] = data }
        }
        return out
    }

    /// True when the store's in-memory list is what the file holds — i.e.
    /// nothing is waiting to be saved. Compared after decoding both sides
    /// the same way, so a file written by an older build (other formatting,
    /// fields since added) still counts as matching.
    private func storeMatchesDisk(_ name: String, _ data: Data) -> Bool {
        let model = AppModel.shared
        switch name {
        case "hosts.json":
            // The flag first: the store normalises headings in memory at
            // load and lets the file catch up on the next edit, so memory and
            // disk can differ with nothing unsaved. A set flag whose content
            // turns out identical (an assignment that changed nothing) is not
            // "unsaved" either.
            return !model.store.hasUnsavedGroups
                || SyncPolicy.sameContent([HostGroup].self, disk: data, memory: model.store.groups)
        case "credentials.json":
            return model.credentialStore.isTrusted
                && SyncPolicy.sameContent([Credential].self, disk: data, memory: model.credentialStore.credentials)
        case "snippets.json":
            return SyncPolicy.sameContent([Snippet].self, disk: data, memory: model.snippetStore.snippets,
                                          decode: { try SnippetCodec.decode($0) })
        default:
            return false
        }
    }

    // MARK: Records in

    func syncApply(_ changes: [String: Data?], firstJoin: Bool) -> SyncApplyResult {
        applying = true
        defer { applying = false }
        var failed: Set<String> = []

        if firstJoin {
            // The cloud is about to replace this Mac's configuration: set it
            // aside first, exactly as a restore does. No snapshot, no apply
            // (and the engine stays in join mode, so the next try asks again).
            do { _ = try BackupManager.snapshotCurrent() } catch {
                NSLog("SheepTerm sync: could not set the configuration aside (%@) — not applying", error.localizedDescription)
                return SyncApplyResult(failed: Set(changes.keys), refusedJoin: true)
            }
        }

        // 1. Files: this Mac's entries with the cloud's changes laid over
        //    them, put back together, checked like a restore, written.
        //    Each file on its own, so one bad file does not hold back the
        //    others.
        var wroteFiles: Set<String> = []
        for family in SyncRecordCodec.families {
            let ids = changes.keys.filter { family.owns($0) }
            guard !ids.isEmpty else { continue }
            let url = BackupManager.baseDirectory.appendingPathComponent(family.file)
            let isQuarantined = quarantined(family.file)
            let current = try? Data(contentsOf: url)
            // An empty base is only right when the snapshot asked for the
            // WHOLE family from the cloud (quarantined, or no file and an
            // empty store). A file that vanished under a store still holding
            // entries — or one that exists but could not be read — is left
            // alone.
            if current == nil, !SyncPolicy.mayApplyWithoutFile(
                quarantined: isQuarantined, fileExists: FileManager.default.fileExists(atPath: url.path),
                storeEmpty: storeIsEmpty(family.file)) {
                failed.formUnion(ids)
                continue
            }
            // Never over a file whose store has changes it could not save:
            // they would be thrown away by the reload below. (A quarantined
            // file is the exception: the cloud copy is the recovery.)
            if !isQuarantined, let current, !storeMatchesDisk(family.file, current) {
                failed.formUnion(ids)
                continue
            }
            do {
                // The base is what is here: the file as it is (for a
                // quarantined family, only what was made since the quarantine
                // — kept), nothing for a missing one (the cloud then brings
                // everything it has).
                var merged = try SyncPolicy.applyBase(current: current) { try SyncRecordCodec.decompose($0, as: family) }
                for id in ids {
                    if let value = changes[id] ?? nil { merged[id] = value } else { merged[id] = nil }
                }
                let composed = try SyncRecordCodec.compose(merged, as: family)
                var payload = BackupManager.Payload(format: BackupManager.currentFormat, app: "sync", created: Date(),
                                                    device: "", files: [family.file: composed], settings: [:])
                try BackupManager.validate(payload)
                _ = try BackupManager.sanitize(&payload)
                guard let clean = payload.files[family.file] else { throw CocoaError(.fileReadCorruptFile) }
                if clean == current { continue }
                try Self.backUpBeforeOverwrite(url)
                try clean.write(to: url, options: .atomic)
                wroteFiles.insert(family.file)
            } catch {
                NSLog("SheepTerm sync: %@ from the cloud not applied: %@", family.file, error.localizedDescription)
                failed.formUnion(ids)
            }
        }

        // 2. Settings — only keys on the list, only values of a known type.
        var wroteSettings = false
        let decoder = JSONDecoder()
        for (id, change) in changes where id.hasPrefix("setting:") {
            let key = String(id.dropFirst("setting:".count))
            guard Self.syncedSettingKeys.contains(key) else { continue }
            if let data = change, let value = try? decoder.decode(BackupManager.Setting.self, from: data) {
                UserDefaults.standard.set(value.objectValue, forKey: key)
                // Only the key written: a setting the user changed meanwhile
                // must still look changed to the defaults observer.
                lastSettings[key] = data
                wroteSettings = true
            } else if change != nil {
                failed.insert(id)
            }
        }

        if !wroteFiles.isEmpty || wroteSettings { AppModel.shared.reloadAfterRestore(files: wroteFiles) }

        // 3. Passwords, after the credential list they belong to — and only
        //    for a credential that list names: a password with no
        //    credential is an orphan nothing can reach (it is retried once
        //    the list that names it has arrived).
        let known = Set(AppModel.shared.credentialStore.credentials.map(\.id))
        let trusted = AppModel.shared.credentialStore.isTrusted
        let listFailed = failed.contains { SyncRecordCodec.credentials.owns($0) }
        for (id, change) in changes where id.hasPrefix(SyncPolicy.passwordPrefix) {
            guard let uuid = UUID(uuidString: String(id.dropFirst(SyncPolicy.passwordPrefix.count))) else { continue }
            switch SyncPolicy.passwordAction(uuid, isDelete: change == nil, listTrusted: trusted, known: known,
                                             listFailedThisRound: listFailed) {
            case .write:
                guard let data = change ?? nil, let password = String(data: data, encoding: .utf8),
                      Keychain.setPasswordWithoutPrompt(password, for: uuid) else { failed.insert(id); continue }
            case .delete:
                if !Keychain.deletePasswordWithoutPrompt(for: uuid) { failed.insert(id) }
            case .skip:
                continue
            case .retry:
                failed.insert(id)
            }
        }
        return SyncApplyResult(failed: failed)
    }

    /// The stores' own rule for overwriting a file: copy it beside the old
    /// .bak and swap, and refuse to write when that copy fails — a file that
    /// cannot be copied is usually one that cannot be READ, and writing over
    /// it would destroy the only copy.
    private static func backUpBeforeOverwrite(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("bak")
        let staging = url.appendingPathExtension("bak.tmp")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: url, to: staging)
            _ = try FileManager.default.replaceItemAt(backup, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
