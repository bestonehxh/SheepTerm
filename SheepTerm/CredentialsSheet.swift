import SwiftUI

/// Manage saved credentials: add new ones and remove old ones.
/// A password goes straight to the Keychain — nothing here keeps a copy.
/// The eye button reads one back out of the Keychain for as long as the row
/// stays revealed; the value is never held in this view's state.
struct CredentialsSheet: View {
    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    /// It looked fine only because every interaction happened to touch some
    /// local @State as well.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var revealedIDs: Set<UUID> = []
    // Credential waiting on the delete confirmation dialog.
    @State private var pendingDelete: Credential?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Credentials")
                .font(.headline)

            if model.credentialStore.credentials.isEmpty {
                Text("No saved credentials yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(model.credentialStore.credentials) { credential in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(credential.name)
                                Text(credential.username)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if revealedIDs.contains(credential.id) {
                                    Text(model.credentialStore.password(for: credential) ?? "(no password stored)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.warn)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button {
                                if revealedIDs.contains(credential.id) {
                                    revealedIDs.remove(credential.id)
                                } else {
                                    revealedIDs.insert(credential.id)
                                }
                            } label: {
                                Image(systemName: revealedIDs.contains(credential.id) ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(revealedIDs.contains(credential.id)
                                  ? "Hide password" : "Show password from Keychain")
                            Button {
                                pendingDelete = credential
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .help("Delete credential")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: min(CGFloat(model.credentialStore.credentials.count) * 40 + 20, 200))
            }

            Divider()

            Text("Add Credential")
                .font(.subheadline.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("netops-prod"))
                TextField("Username", text: $username, prompt: Text("admin"))
                RevealableSecureField(title: "Password", text: $password)
            }
            .textFieldStyle(.roundedBorder)
            // Return in one of these fields adds the credential. "Done" is
            // the default button, so without this the Return that ends
            // typing a password closed the sheet and threw it away.
            .onSubmit(add)

            HStack {
                Button("Add") { add() }
                    // A credential without a password is useless — every
                    // connect would still prompt interactively.
                    // Exactly the test add() makes, so the button is never
                    // enabled for input add() would then refuse.
                    .disabled(!canAdd)
                Spacer()
                // Done keeps a finished credential instead of dropping it.
                // Typing name, username and password and then pressing the
                // button that says you are done reads as "save this" — it
                // threw the whole thing away without a word, which is the
                // same trap Return used to be.
                Button("Done") {
                    if canAdd { add() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .sheepSheetChrome()
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
        }
        .alert("Delete credential?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { credential in
            Button("Delete", role: .destructive) { delete(credential) }
            Button("Cancel", role: .cancel) {}
        } message: { credential in
            let count = model.store.hostCount(usingCredential: credential.id)
            if count == 0 {
                Text("“\(credential.name)” is not used by any saved host.")
            } else {
                Text("\(count) saved host\(count == 1 ? "" : "s") use\(count == 1 ? "s" : "") “\(credential.name)”. Deleting it also removes the reference — \(count == 1 ? "that host" : "those hosts") will fall back to manual password entry.")
            }
        }
    }

    /// The one test for "is there a credential here to keep": the Add button,
    /// Return and Done all ask it, so none of them can disagree with `add()`.
    private var canAdd: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func add() {
        // whitespacesAndNewlines: .whitespaces keeps the newline a pasted
        // value carries, and " admin\n" fails authentication while looking
        // exactly like "admin" in the list. The PASSWORD is never trimmed —
        // a leading or trailing space can be part of it.
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        uiTrace("CredentialsSheet.add user=\(trimmedUser.isEmpty ? "<empty>" : "set") password=\(password.isEmpty ? "<empty>" : "set") existing=\(model.credentialStore.credentials.count)")
        guard !trimmedUser.isEmpty, !password.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.credentialStore.add(
            name: trimmedName.isEmpty ? trimmedUser : trimmedName,
            username: trimmedUser,
            password: password
        )
        uiTrace("CredentialsSheet.add done, store now has \(model.credentialStore.credentials.count)")
        name = ""
        username = ""
        password = ""
    }

    /// Removes the credential and clears it from every host that
    /// references it, so no host points at a dead Keychain entry.
    private func delete(_ credential: Credential) {
        // The credential goes FIRST, because it is the step that can fail. It
        // rolls itself back when credentials.json cannot be written, and the
        // two steps below cannot be rolled back with it — they were running
        // first, so a failed write left the credential restored to the list
        // with every host's reference to it already stripped and saved.
        guard model.credentialStore.remove(credential) else { return }
        // Still before the hosts lose the reference — that is how they are found.
        model.forgetCachedPasswords(forCredential: credential.id)
        model.store.clearCredentialID(credential.id)
    }
}
