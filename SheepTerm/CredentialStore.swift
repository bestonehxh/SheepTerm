import AppKit
import Combine
import Foundation


/// Credential metadata lives in credentials.json; the password itself only
/// ever lives in the macOS Keychain, keyed by the credential's UUID.
@MainActor
final class CredentialStore: ObservableObject {
    @Published var credentials: [Credential]

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("credentials.json")
    }

    /// Set when credentials.json was unreadable at load: blocks automatic
    /// writes until the user explicitly changes something.
    ///
    /// This file is the POINTER to every password in the Keychain. Loading
    /// it as an empty list and then saving over it — which is what the old
    /// `try?`-and-fall-back-to-`[]` did on any transient read failure —
    /// destroys the names and usernames AND orphans every Keychain item,
    /// because the items are keyed by the UUIDs that just went away. Nothing
    /// in the app can reach an orphaned item again. So credentials.json now
    /// gets the same treatment hosts.json has always had: the unreadable
    /// original is preserved, writes stop until the user acts, and every
    /// write leaves a .bak behind.
    private var suppressWritesAfterCorruptLoad = false

    /// False while the list is what a failed load left (empty, writes held):
    /// then it says nothing about which credentials exist, and Sync must not
    /// read a password's absence from it as "deleted".
    /// Unlike the write suppression, this does NOT clear on the user's next
    /// edit: one credential added after a quarantine must not be uploaded as
    /// "the whole list" and tombstone every password on every Mac. Cleared
    /// by the next clean reload (a restore, or Sync bringing the list down).
    var isTrusted: Bool { !quarantinedSinceLoad }
    private var quarantinedSinceLoad = false

    init() {
        let (loaded, warning) = Self.load()
        credentials = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        quarantinedSinceLoad = warning != nil
        // Deferred: this runs from `AppModel.init`, i.e. while the SwiftUI
        // `App` is still being constructed and no window exists. A modal
        // there is the same mistake as the one in the Apple Event callback
        // (ARCHITECTURE §11) — run it once the run loop is up.
        if let warning { DispatchQueue.main.async { Self.reportCorruptLoad(warning) } }
    }

    /// Re-reads credentials.json after a backup restore.
    ///
    /// Passwords are not part of a backup, so a credential restored from
    /// another Mac has no Keychain entry here. NOTE: it will be prompted for
    /// on EVERY connection, not stored after the first: connecting never
    /// re-saves it. Passwords → Edit (or Update after a web login typed by
    /// hand) stores it; that is the way to fix it.
    func reloadFromDisk() {
        let (loaded, warning) = Self.load()
        credentials = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        quarantinedSinceLoad = warning != nil
        if let warning { DispatchQueue.main.async { Self.reportCorruptLoad(warning) } }
    }

    /// A missing file is normal (fresh install). A file that exists but does
    /// not decode is data the user had, so it is preserved rather than
    /// overwritten — same rule, same naming, as HostStore.loadList.
    private static func load() -> (value: [Credential], warning: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Same rule as hosts.json: unreadable is not empty (see Models).
            if !FileManager.default.fileExists(atPath: fileURL.path) { return ([], nil) }
            let warning = String(localized: "\(fileURL.lastPathComponent) could not be read (\(error.localizedDescription)). The credential list starts empty and the file will not be overwritten until you change something.")
            NSLog("SheepTerm: %@", warning)
            return ([], warning)
        }
        do {
            return (try JSONDecoder().decode([Credential].self, from: data), nil)
        } catch {
            let corruptURL = fileURL.appendingPathExtension("corrupt-\(corruptStamp())")
            do {
                try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            } catch {
                NSLog("SheepTerm: could not move corrupt credentials.json aside: %@",
                      error.localizedDescription)
            }
            let warning = String(localized: "credentials.json was unreadable; the original was preserved as \(corruptURL.lastPathComponent). Your saved passwords are still in the Keychain, but SheepTerm cannot see which is which until the file is restored or the credentials are re-added.")
            NSLog("SheepTerm: %@ (decode error: %@)", warning, error.localizedDescription)
            return ([], warning)
        }
    }

    /// A timestamp that ends up in a FILE NAME is always Gregorian + POSIX,
    /// for the reason spelled out on HostStore.corruptStamp.
    private static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Re-arms saving after a corrupt load. Every mutator calls this: an
    /// automatic write must not overwrite the rescued file, but a change the
    /// user just made deliberately should.
    private func noteUserMutation() {
        suppressWritesAfterCorruptLoad = false
    }

    /// True when what is in memory is now what is on disk. `remove` needs that
    /// answer before it touches the Keychain — see there.
    @discardableResult
    func save() -> Bool {
        guard !suppressWritesAfterCorruptLoad else {
            NSLog("SheepTerm: write to credentials.json suppressed until the first user change (corrupt previous file was preserved)")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Swallowing this with try? left credentials.json silently out of
        // sync with what the UI shows as saved — the failure has to reach
        // the person editing, the same way a Keychain write failure does
        // below, or they lose data with no clue why.
        do {
            let data = try encoder.encode(credentials)
            if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                // Staged and swapped, as `HostStore.write` does: remove-then-
                // copy left NO backup when the copy failed, which is the one
                // moment a backup is wanted.
                let backupURL = Self.fileURL.appendingPathExtension("bak")
                let stagingURL = Self.fileURL.appendingPathExtension("bak.tmp")
                do {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.copyItem(at: Self.fileURL, to: stagingURL)
                    _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: stagingURL)
                } catch {
                    try? FileManager.default.removeItem(at: stagingURL)
                    // Never overwrite a file that could not be backed up: an
                    // existing file we cannot READ (permissions, a cloud file
                    // never downloaded) fails the copy for the same reason,
                    // and the atomic write below would then replace the only
                    // copy of every credential — orphaning every Keychain
                    // item, since they are keyed by the ids in that file.
                    NSLog("SheepTerm: could not back up credentials.json (%@) — not overwriting it",
                          error.localizedDescription)
                    throw error
                }
            }
            try data.write(to: Self.fileURL, options: .atomic)
            return true
        } catch {
            Self.reportSaveFailure(error)
            return false
        }
    }

    private static func reportCorruptLoad(_ warning: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Saved credentials could not be read")
        alert.informativeText = warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.sheepStyled().runModal()
    }

    private static func reportSaveFailure(_ error: Error) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Credentials not saved")
        alert.informativeText = String(localized: "SheepTerm could not write credentials.json (\(error.localizedDescription)). The change you just made to the credential list is not saved.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.sheepStyled().runModal()
    }

    @discardableResult
    func add(name: String, username: String, password: String, websites: [String] = []) -> Credential {
        // The NAME goes through the store's own name pass (the one door every
        // caller shares — there is no rename for a credential). A name with an
        // inner tab or newline only had its ENDS trimmed, and once it was
        // picked into the Add Hosts Credential cell it read as a block paste
        // and spread into the next column. The username is left exactly as
        // given: it is a login, and changing it would change who logs in.
        let cleaned = ConfigurationHygiene.cleanedName(name)
        // Everything stripped = nothing readable was ever typed (a name of
        // pure control characters). Storing the RAW input put an invisible
        // label in every picker and alert; every other name door in the
        // stores refuses instead, so this one does too.
        let sites = WebLoginKey.cleanedSites(websites)
        let credential = Credential(
            name: cleaned.isEmpty ? String(localized: "Unnamed Credential") : cleaned,
            username: username, websites: sites.isEmpty ? nil : sites)
        noteUserMutation()
        credentials.append(credential)
        uiTrace("CredentialStore.add appended \(credential.name) → \(credentials.count) entries")
        // The Keychain item is keyed by an id that exists only in
        // credentials.json. If that file did not take the new entry, a
        // password stored anyway is an orphan nothing can ever reach — the
        // list forgets the credential at the next launch and the Keychain
        // keeps its secret forever. `save()` has already told the user.
        guard save() else { return credential }
        // The Keychain CAN refuse (locked keychain, denied access). Saying
        // nothing left the credential listed as if it had a password, and
        // every connect would then prompt with no clue why — the failure has
        // to reach the person who just typed it, not only the log.
        if !password.isEmpty, !Keychain.setPassword(password, for: credential.id) {
            Self.reportKeychainFailure(for: credential)
        }
        return credential
    }

    /// Share Link import: credentials whose passwords are ALREADY in the Keychain, added in one save. False (nothing added) when
    /// credentials.json did not take them — `save()` has told the user, and the caller removes the passwords.
    func addImported(_ list: [Credential]) -> Bool {
        guard !list.isEmpty else { return true }
        noteUserMutation()
        credentials.append(contentsOf: list)
        guard save() else {
            let ids = Set(list.map(\.id))
            credentials.removeAll { ids.contains($0.id) }
            return false
        }
        return true
    }

    private static func reportKeychainFailure(for credential: Credential) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Password not saved to the Keychain")
        alert.informativeText = String(localized: "“\(credential.name)” was saved, but macOS refused to store its password. SheepTerm will ask for it on every connection until the credential is added again with the Keychain unlocked.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.sheepStyled().runModal()
    }

    /// Passwords page / Save login: a credential's name, user or web sites
    /// changed (the password goes through `Keychain.setPassword`). False when
    /// it is not there any more or the file did not take it.
    @discardableResult
    func update(_ credential: Credential) -> Bool {
        guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else { return false }
        var changed = credential
        let cleaned = ConfigurationHygiene.cleanedName(credential.name)
        changed.name = cleaned.isEmpty ? credentials[index].name : cleaned
        changed.websites = WebLoginKey.cleanedSites(credential.websites ?? [])
        if changed.websites?.isEmpty == true { changed.websites = nil }
        guard changed != credentials[index] else { return true }
        let before = credentials[index]
        noteUserMutation()
        credentials[index] = changed
        guard save() else {
            credentials[index] = before
            return false
        }
        return true
    }

    /// Save login: `origin`'s site joins the credential's list (no-op when
    /// it is there already).
    @discardableResult
    func addWebsite(_ origin: String, to id: UUID) -> Bool {
        guard var credential = credential(for: id), let site = WebLoginKey.siteKey(origin) else { return false }
        var sites = credential.websites ?? []
        guard !sites.contains(site) else { return true }
        sites.append(site)
        credential.websites = sites
        return update(credential)
    }

    func credential(for id: UUID?) -> Credential? {
        guard let id else { return nil }
        return credentials.first { $0.id == id }
    }

    func password(for credential: Credential) -> String? {
        Keychain.password(for: credential.id)
    }

    /// False when nothing was removed, so the caller can leave the rest of the
    /// configuration alone. `CredentialsSheet.delete` also strips the id off
    /// every host and out of the password cache, and doing that around a
    /// rollback would swap one inconsistency for another: the credential back
    /// in the list with no host pointing at it any more.
    @discardableResult
    func remove(_ credential: Credential) -> Bool {
        noteUserMutation()
        let index = credentials.firstIndex { $0.id == credential.id }
        credentials.removeAll { $0.id == credential.id }
        // "Only after its metadata is safely gone" is what the comment here
        // used to claim while `save()` returned Void, so the Keychain item went
        // whatever happened to the file. A failed write (full disk, a file-sync
        // client holding the file) then left the credential still LISTED on
        // disk with its password already deleted: it comes back on the next
        // launch, authenticates against nothing, and the reason is invisible.
        // Put it back instead — what is on screen then matches what is on
        // disk, and `save()` has already told the user why.
        guard save() else {
            if let index { credentials.insert(credential, at: min(index, credentials.count)) }
            else { credentials.append(credential) }
            return false
        }
        // If the Keychain refuses (locked, denied), the item would otherwise
        // stay forever with nothing left that can name it — so say so.
        if !Keychain.deletePassword(for: credential.id) {
            Self.reportKeychainDeleteFailure(for: credential)
        }
        return true
    }

    private static func reportKeychainDeleteFailure(for credential: Credential) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Password not removed from the Keychain")
        alert.informativeText = String(localized: "“\(credential.name)” was removed from SheepTerm, but macOS refused to delete its stored password. It is still in your login keychain under “Bestchaan.SheepTerm” and SheepTerm can no longer reach it — remove it in Keychain Access if you want it gone.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.sheepStyled().runModal()
    }
}

/// Credential passwords, all inside the one-item `PasswordVault` (5.0 (14)):
/// one Keychain prompt per update instead of one per host.
enum Keychain {
    private static var vault: PasswordVault { .shared }

    /// Returns false when the password did not land in the Keychain —
    /// callers must surface that, never swallow it.
    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool {
        vault.set(Data(password.utf8), for: id.uuidString, interactive: true)
    }

    static func password(for id: UUID) -> String? {
        vault.value(for: id.uuidString, interactive: true).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// For Sync's background reads: never put up a Keychain access prompt
    /// (a vault nobody has opened yet reads as "unavailable" instead of
    /// interrupting the user every five minutes).
    static func passwordWithoutPrompt(for id: UUID) -> String? {
        vault.value(for: id.uuidString, interactive: false).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Sync's write: never a prompt. Not written = Sync retries later.
    static func setPasswordWithoutPrompt(_ password: String, for id: UUID) -> Bool {
        vault.set(Data(password.utf8), for: id.uuidString, interactive: false)
    }

    /// Sync's delete: never a prompt (see above).
    static func deletePasswordWithoutPrompt(for id: UUID) -> Bool {
        vault.remove(id.uuidString, interactive: false)
    }

    /// Reports success so the caller can tell the user: a refused delete
    /// leaves the secret in the keychain with its metadata already gone, and
    /// nothing in the app can name it again.
    @discardableResult
    static func deletePassword(for id: UUID) -> Bool {
        vault.remove(id.uuidString, interactive: true)
    }
}
