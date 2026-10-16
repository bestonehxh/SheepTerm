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
                Text("Passwords").font(.headline)
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
                Text(credentialStore.credentials.isEmpty ? "No saved passwords yet" : "No match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List(rows) { credential in row(credential) }
                    .frame(height: min(rows.reduce(16) { $0 + (($1.websites ?? []).isEmpty ? 50 : 66) }
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
                if revealedIDs.contains(credential.id) {
                    Text(credentialStore.password(for: credential) ?? "(no password stored)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.warn)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                icon("person", help: "Copy username") { copy(credential.username) }
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

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
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
                                                         localizedReason: "show your saved passwords")) ?? false
            guard ok else { return }
            unlockedUntil = Date().addingTimeInterval(PasswordsPlan.unlockSeconds)
            then()
        }
    }

    /// A copied password leaves the clipboard after a minute, unless
    /// something else was copied meanwhile.
    private func copy(_ text: String, secret: Bool = false) {
        guard !text.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard secret else { return }
        // Clipboard managers skip what is marked concealed (nspasteboard.org).
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    /// Delete asks first, in the app's centred alert. Cancel is the default (Return).
    private func confirmDelete(_ credential: Credential) {
        let count = model.store.hostCount(usingCredential: credential.id)
        let alert = SheepAlert()
        alert.messageText = "Delete “\(credential.name)”?"
        alert.informativeText = count == 0
            ? "It is not used by any saved host."
            : "\(count) saved host\(count == 1 ? "" : "s") use\(count == 1 ? "s" : "") it — \(count == 1 ? "that host" : "those hosts") will ask for the password when connecting."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
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

    init(edit: CredentialEdit, done: @escaping () -> Void) {
        self.edit = edit
        self.done = done
        if let credential = edit.credential {
            _name = State(initialValue: credential.name)
            _username = State(initialValue: credential.username)
            _sites = State(initialValue: PasswordsPlan.field(for: credential.websites))
        }
    }

    private var isNew: Bool { edit.credential == nil }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A new login needs a user and a password; an edit only a user.
    private var canSave: Bool { !trimmedUser.isEmpty && (!isNew || !password.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Password" : "Edit Password").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("Lab FortiGate"))
                TextField("Username", text: $username, prompt: Text("admin"))
                RevealableSecureField(title: "Password", text: $password)
                    .help(isNew ? "" : "Leave empty to keep the saved password")
                TextField("Websites", text: $sites, prompt: Text("192.168.225.39"), axis: .vertical)
                    .lineLimit(1...4)
                    .help("One per line — a bare address means https")
            }
            .textFieldStyle(.roundedBorder)
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
        .frame(width: 420)
        .sheepSheetChrome()
        .noAutoFill()
        .onAppear { AuthPrompt.forceASCIIKeyboard() }
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let websites = PasswordsPlan.sites(fromField: sites)
        if var credential = edit.credential {
            credential.name = trimmedName.isEmpty ? trimmedUser : trimmedName
            credential.username = trimmedUser
            credential.websites = websites
            guard credentialStore.update(credential) else { NSSound.beep(); return }
            // The PASSWORD is never trimmed — a leading or trailing space can be part of it.
            if !password.isEmpty {
                guard Keychain.setPassword(password, for: credential.id) else { NSSound.beep(); return }
                // Sessions that logged in with the old one must not reuse it.
                AppModel.shared.forgetCachedPasswords(forCredential: credential.id)
            }
        } else {
            _ = credentialStore.add(name: trimmedName.isEmpty ? trimmedUser : trimmedName,
                                    username: trimmedUser, password: password, websites: websites)
        }
        done()
    }
}
