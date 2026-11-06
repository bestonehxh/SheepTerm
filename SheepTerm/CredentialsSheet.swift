import AppKit
import Combine
import LocalAuthentication
import SwiftUI

/// The Passwords page (5.0 (24), Safari's; was "Credentials"): every saved
/// login with its web sites, a search, and — after Touch ID or the Mac's
/// login password — the password itself (shown, copied, changed). The
/// password never lives in this view's state: it is read from the Keychain
/// vault for as long as a row shows it, and the edit form keeps a NEW one
/// only until Save. Rules in `PasswordsPlan` (harness-tested).
struct CredentialsSheet: View {
    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var revealedIDs: Set<UUID> = []
    /// One Touch ID answer opens the passwords for `PasswordsPlan.unlockSeconds`.
    @State private var unlockedUntil: Date?
    @State private var editing: CredentialEdit?
    /// Held by the view, not built in `body`: a redraw (each search
    /// keystroke) must not restart the countdown.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Credentials").font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button { editing = CredentialEdit(credential: nil) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a password")
            }

            let rows = PasswordsPlan.rows(credentialStore.credentials, query: query)
            if rows.isEmpty {
                Text(credentialStore.credentials.isEmpty ? String(localized: "No saved passwords yet") : String(localized: "No match"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List(rows) { credential in row(credential) }
                    .frame(height: min(rows.reduce(16) { $0 + (($1.websites ?? []).isEmpty ? 50 : 66) + ($1.publicKey == nil ? 0 : 16) + ($1.certificate == nil ? 0 : 16) }
                                       + CGFloat(revealedIDs.count) * 16, 380))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheepSheetChrome()
        .onExitCommand { dismiss() }
        .noAutoFill()
        // A shown password hides again when the unlock window ends.
        .onReceive(tick) { now in
            let still = PasswordsPlan.revealed(revealedIDs, until: unlockedUntil, now: now)
            if still != revealedIDs { revealedIDs = still }
        }
        .sheet(item: $editing) { edit in
            CredentialEditSheet(edit: edit) { editing = nil }
        }
    }

    private func row(_ credential: Credential) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.name).font(.system(size: 12, weight: .medium))
                Text(credential.username.isEmpty ? "—" : credential.username)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let sites = credential.websites, !sites.isEmpty {
                    Text(sites.map(PasswordsPlan.display).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let line = credential.publicKey, let summary = SSHIdentity.summary(ofPublicLine: line) {
                    Text(summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let line = credential.certificate, let summary = SSHIdentity.certificateSummary(line) {
                    Text(summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if revealedIDs.contains(credential.id) {
                    Text(credentialStore.password(for: credential) ?? String(localized: "(no password stored)"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.warn)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                icon("person", help: "Copy username") { copy(credential.username) }
                if let line = credential.publicKey {
                    // Public: no unlock, no clipboard timeout.
                    icon("key.horizontal", help: "Copy public key") { copy(line) }
                }
                icon("key", help: "Copy password") {
                    unlock { copy(credentialStore.password(for: credential) ?? "", secret: true) }
                }
                icon(revealedIDs.contains(credential.id) ? "eye.slash" : "eye",
                     help: revealedIDs.contains(credential.id) ? "Hide password" : "Show password") {
                    if revealedIDs.contains(credential.id) {
                        revealedIDs.remove(credential.id)
                    } else {
                        unlock { revealedIDs.insert(credential.id) }
                    }
                }
                icon("pencil", help: "Edit") {
                    unlock { editing = CredentialEdit(credential: credential) }
                }
                Button { confirmDelete(credential) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.destructive)
                .help("Delete")
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
    }

    private func icon(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }

    /// Touch ID / the Mac's login password, once per `unlockSeconds`.
    private func unlock(_ then: @escaping () -> Void) {
        if PasswordsPlan.isUnlocked(until: unlockedUntil, now: Date()) { then(); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No Touch ID and no login password to ask (a Mac without one):
            // nothing stronger to ask for than being logged in.
            unlockedUntil = Date().addingTimeInterval(PasswordsPlan.unlockSeconds)
            then()
            return
        }
        Task { @MainActor in
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                         localizedReason: String(localized: "show your saved passwords"))) ?? false
            guard ok else { return }
            unlockedUntil = Date().addingTimeInterval(PasswordsPlan.unlockSeconds)
            then()
        }
    }

    /// A copied password leaves the clipboard after a minute, unless
    /// something else was copied meanwhile.
    private func copy(_ text: String, secret: Bool = false) {
        guard !text.isEmpty else { NSSound.beep(); return }
        if secret { SecretPasteboard.copy(text); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Delete asks first, in the app's centred alert. Cancel is the default (Return).
    private func confirmDelete(_ credential: Credential) {
        let count = model.store.hostCount(usingCredential: credential.id)
        let alert = SheepAlert()
        alert.messageText = String(localized: "Delete “\(credential.name)”?")
        alert.informativeText = count == 0
            ? String(localized: "It is not used by any saved host.")
            : String(localized: "\(count) saved hosts use it — those hosts will ask for the password when connecting.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        if alert.runModal() == .alertSecondButtonReturn {
            // The credential goes FIRST: it is the step that can fail, and
            // the two below cannot be rolled back with it.
            guard model.credentialStore.remove(credential) else { return }
            model.forgetCachedPasswords(forCredential: credential.id)
            model.store.clearCredentialID(credential.id)
            revealedIDs.remove(credential.id)
        }
    }
}

/// One showing of the add / edit form (nil credential = a new one).
struct CredentialEdit: Identifiable {
    let id = UUID()
    let credential: Credential?
}

/// Add or edit one login: name, user, password (empty on edit = keep the
/// saved one), web sites (one per line; a bare host means https).
struct CredentialEditSheet: View {
    let edit: CredentialEdit
    let done: () -> Void
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sites = ""
    /// The key as the form shows it: the saved public line, or the one of a
    /// key just imported / generated (nil = no key).
    @State private var publicLine: String?
    /// A key imported or generated in this form, written at Save.
    @State private var pendingKey: StoredKey?
    @State private var passphrase = ""
    @State private var needsPassphrase = false
    @State private var keyProblem: String?
    /// The key's OpenSSH certificate (6.1), a `-cert.pub` line; nil = none.
    @State private var certificate: String?

    init(edit: CredentialEdit, done: @escaping () -> Void) {
        self.edit = edit
        self.done = done
        if let credential = edit.credential {
            _name = State(initialValue: credential.name)
            _username = State(initialValue: credential.username)
            _sites = State(initialValue: PasswordsPlan.field(for: credential.websites))
            _publicLine = State(initialValue: credential.publicKey)
            _certificate = State(initialValue: credential.certificate)
        }
    }

    private var isNew: Bool { edit.credential == nil }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A new login needs a user and a password or a key; an edit only a user.
    private var canSave: Bool { !trimmedUser.isEmpty && (!isNew || !password.isEmpty || pendingKey != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? String(localized: "Add Credential") : String(localized: "Edit Credential")).font(.headline)
            // The host forms' layout (6.0 (36), the user: the key and certificate
            // rows looked odd): one label column, one field column, every row
            // the same height — the key and the certificate are boxes like fields.
            Form {
                TextField("Name", text: $name, prompt: Text("Lab FortiGate"))
                    .formRow("Name")
                TextField("Username", text: $username, prompt: Text("admin"))
                    .formRow("Username")
                RevealableSecureField(title: "Password", text: $password)
                    .formRow("Password")
                    .help(isNew ? "" : String(localized: "Leave empty to keep the saved password"))
                TextField("Websites", text: $sites, prompt: Text("192.168.225.39"), axis: .vertical)
                    .lineLimit(1...4)
                    .formRow("Websites")
                    .help("One per line — a bare address means https")
                keyRow
                // An encrypted key takes its certificate now too (Fable).
                if publicLine != nil || pendingKey != nil { certificateRow }
                if needsPassphrase {
                    RevealableSecureField(title: "Passphrase", text: $passphrase)
                        .formRow("Passphrase")
                }
            }
            .textFieldStyle(.roundedBorder)
            if let keyProblem {
                Text(keyProblem).font(.system(size: 11)).foregroundStyle(Theme.destructive)
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: SheetLayout.width)
        .sheepSheetChrome()
        .noAutoFill()
        .onAppear { AuthPrompt.forceASCIIKeyboard() }
    }

    /// SSH Key: a box like a field — the key's type and the end of its
    /// fingerprint, Copy / Remove inside it; Import… / Generate when there is none.
    @ViewBuilder private var keyRow: some View {
        Group {
            if let line = publicLine {
                ValueBox(text: SSHIdentity.shortSummary(ofPublicLine: line) ?? line, help: line) {
                    Button { copyPublic(line) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy public key").accessibilityLabel("Copy public key")
                    Button { removeKey() } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Remove key").accessibilityLabel("Remove key")
                }
            } else if pendingKey != nil {
                // An encrypted key waiting for its passphrase (below): a box
                // like a loaded key's, so a second Import cannot silently
                // replace it (Fable) — Remove first.
                ValueBox(text: String(localized: "Encrypted key — enter its passphrase"), help: "") {
                    Button { removeKey() } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Remove key").accessibilityLabel("Remove key")
                }
            } else {
                HStack(spacing: 8) {
                    Button("Import…") { importKey() }
                        .help("A private key file — OpenSSH or PEM")
                    Button("Generate") { generateKey() }
                        .help("A new Ed25519 key")
                    Spacer(minLength: 0)
                }
            }
        }
        .formRow("SSH Key")
    }

    /// Certificate: the `-cert.pub` ssh-keygen -s made for this key — its
    /// id and expiry in a box like the key's, Remove inside; or Import….
    @ViewBuilder private var certificateRow: some View {
        Group {
            if let line = certificate {
                ValueBox(text: SSHIdentity.certificateSummary(line, compact: true) ?? line, help: SSHIdentity.certificateSummary(line) ?? line) {
                    Button { certificate = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Remove certificate").accessibilityLabel("Remove certificate")
                }
            } else {
                HStack {
                    Button("Import…") { importCertificate() }
                        .help("The key's -cert.pub file, signed by your CA")
                    Spacer(minLength: 0)
                }
            }
        }
        .formRow("Certificate")
    }

    private func importCertificate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            keyProblem = String(localized: "That file is not a certificate.")
            return
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch SSHIdentity.inspectCertificate(line, publicKey: publicLine) {
        case .success:
            certificate = line; keyProblem = nil
        case .failure(.otherKey):
            keyProblem = String(localized: "That certificate is for a different key.")
        case .failure(.notUserCertificate):
            keyProblem = String(localized: "That is a host certificate, not a user certificate.")
        case .failure(.unreadable(let why)):
            keyProblem = String(localized: "Not a certificate SheepTerm can read: \(why)")
        }
    }

    private func copyPublic(_ line: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    private func removeKey() {
        publicLine = nil
        certificate = nil
        pendingKey = nil
        passphrase = ""
        needsPassphrase = false
        keyProblem = nil
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A key file is a few KB; anything far bigger is not one.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            keyProblem = String(localized: "That file is not a private key.")
            return
        }
        let key = StoredKey(text: text, passphrase: nil)
        keyProblem = nil
        switch SSHIdentity.inspect(key) {
        case .success(let line):
            pendingKey = key; publicLine = line; needsPassphrase = false
        case .failure(.needsPassphrase), .failure(.wrongPassphrase):
            pendingKey = key; publicLine = nil; needsPassphrase = true
        case .failure(.unreadable(let why)):
            keyProblem = String(localized: "Not a key SheepTerm can read: \(why)")
        }
    }

    private func generateKey() {
        let comment = trimmedUser.isEmpty ? "sheepterm" : "\(trimmedUser)@sheepterm"
        let key = SSHIdentity.generateEd25519(comment: comment)
        guard case .success(let line) = SSHIdentity.inspect(key) else { NSSound.beep(); return }
        pendingKey = key; publicLine = line; needsPassphrase = false; keyProblem = nil
    }

    /// The key change this Save makes: nil = none; `.some(nil)` = remove the
    /// saved key; otherwise the key and its public line. Nil overall when an
    /// encrypted key's passphrase does not open it (the form stays up).
    private func resolvedKey() -> (change: (key: StoredKey, line: String)??, ok: Bool) {
        if let pendingKey {
            var key = pendingKey
            key.passphrase = needsPassphrase && !passphrase.isEmpty ? passphrase : nil
            switch SSHIdentity.inspect(key) {
            case .success(let line): return (.some((key, line)), true)
            case .failure(.needsPassphrase): keyProblem = String(localized: "This key needs its passphrase.")
            case .failure(.wrongPassphrase): keyProblem = String(localized: "Wrong passphrase.")
            case .failure(.unreadable(let why)): keyProblem = String(localized: "Not a key SheepTerm can read: \(why)")
            }
            return (nil, false)
        }
        if publicLine == nil, edit.credential?.publicKey != nil { return (.some(nil), true) }
        return (nil, true)
    }

    /// Writes the key change for `id`; the public line to store (or nil), or
    /// false when the Keychain refused — the key goes in BEFORE the
    /// credential names it, so a credential never points at a missing key.
    private func applyKey(_ change: (key: StoredKey, line: String)??, to id: UUID, current: String?) -> (line: String?, ok: Bool) {
        switch change {
        case .none: return (current, true)
        case .some(.none): return (nil, Keychain.deleteKey(for: id))
        case .some(.some(let new)): return (new.line, Keychain.setKey(new.key, for: id))
        }
    }

    private func save() {
        guard canSave else { return }
        let key = resolvedKey()
        guard key.ok else { NSSound.beep(); return }
        // A certificate imported beside an encrypted key could not be checked
        // then (no public line yet): check it now (Fable round 2).
        if let certificate {
            let line: String? = {
                if case .some(.some(let new)) = key.change { return new.line }
                return publicLine ?? edit.credential?.publicKey
            }()
            if case .failure(let problem) = SSHIdentity.inspectCertificate(certificate, publicKey: line) {
                switch problem {
                case .otherKey: keyProblem = String(localized: "That certificate is for a different key.")
                case .notUserCertificate: keyProblem = String(localized: "That is a host certificate, not a user certificate.")
                case .unreadable(let why): keyProblem = String(localized: "Not a certificate SheepTerm can read: \(why)")
                }
                return
            }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let websites = PasswordsPlan.sites(fromField: sites)
        if var credential = edit.credential {
            credential.name = trimmedName.isEmpty ? trimmedUser : trimmedName
            credential.username = trimmedUser
            credential.websites = websites
            let applied = applyKey(key.change, to: credential.id, current: credential.publicKey)
            guard applied.ok else { keyProblem = String(localized: "macOS refused to store the key in the Keychain."); return }
            credential.publicKey = applied.line
            credential.certificate = applied.line == nil ? nil : certificate
            guard credentialStore.update(credential) else { NSSound.beep(); return }
            // The PASSWORD is never trimmed — a leading or trailing space can be part of it.
            if !password.isEmpty {
                guard Keychain.setPassword(password, for: credential.id) else { NSSound.beep(); return }
                // Sessions that logged in with the old one must not reuse it.
                AppModel.shared.forgetCachedPasswords(forCredential: credential.id)
            }
        } else {
            var added = credentialStore.add(name: trimmedName.isEmpty ? trimmedUser : trimmedName,
                                            username: trimmedUser, password: password, websites: websites)
            if key.change != nil {
                let applied = applyKey(key.change, to: added.id, current: nil)
                if applied.ok {
                    added.publicKey = applied.line
                    added.certificate = applied.line == nil ? nil : certificate
                    _ = credentialStore.update(added)
                } else {
                    // The login is saved already; staying up would add it twice.
                    let alert = SheepAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Key not saved to the Keychain")
                    alert.informativeText = String(localized: "“\(added.name)” was saved without its key. Edit it to add the key again with the Keychain unlocked.")
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.sheepStyled().runModal()
                }
            }
        }
        done()
    }
}

/// A read-only value drawn like a text field (same height, fill and corner),
/// its buttons inside on the right — the credential's key and certificate.
private struct ValueBox<Buttons: View>: View {
    let text: String
    let help: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            HStack(spacing: 6) { buttons() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))
    }
}
