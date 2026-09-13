import SwiftUI

/// One credential for a whole group (right-click a group → Set Credential for
/// Group…). The thirteen-switch case: every box in the group logs in as
/// `admin`, and doing that through Edit Host is thirteen sheets.
///
/// Only the reference is written — `credentialID` — exactly as everywhere
/// else; the password stays in the Keychain and is never read here.
struct GroupCredentialSheet: View {
    let request: GroupCredentialRequest

    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    /// Same reason as HostEditSheet.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    /// THREE states, not an optional id: a mixed group opens on `.unset`,
    /// which is not the same answer as `.none`. While they were one value,
    /// picking "None" over a mixed group changed nothing the code could see,
    /// so Apply could never be enabled for it — and before that, Return over
    /// the same sheet detached the credential from every host that had one.
    @State private var choice: HostStore.GroupCredentialChoice = .unset
    /// Set once, from the group the sheet was opened on.
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Credential for “\(groupName)”")
                .font(.headline)

            Picker("Credential", selection: $choice) {
                // Only there while nothing is picked — a mixed group has no
                // current answer to show, and "None" must not stand in for
                // one.
                if choice == .unset {
                    Text("Choose…").tag(HostStore.GroupCredentialChoice.unset)
                }
                Text("None (ask when connecting)").tag(HostStore.GroupCredentialChoice.none)
                ForEach(credentialStore.credentials) { credential in
                    Text("\(credential.name) (\(credential.username))")
                        .tag(HostStore.GroupCredentialChoice.credential(credential.id))
                }
            }

            Text(effectDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Only the reference is stored — passwords stay in the Keychain. Serial consoles in the group are left alone.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!HostStore.groupCredentialApplyEnabled(
                        hosts: group?.hosts ?? [], choice: choice))
            }
        }
        .padding(20)
        .frame(width: 380)
        .sheepSheetChrome()
        .onAppear {
            // Opens on what the group ALREADY has, so Return changes nothing
            // by accident: the sheet used to open on "None (ask when
            // connecting)" whatever the hosts held, and Return then detached
            // the credential from every host in the group. nil only when the
            // hosts disagree or none has one — and `isNoChange` keeps Apply
            // disabled until the choice is actually different.
            guard !seeded else { return }
            seeded = true
            let hosts = group?.hosts ?? []
            // A group that agrees with itself opens on what it has; one that
            // does not opens on nothing at all.
            guard HostStore.credentialIsUniform(in: hosts) else { return }
            guard let shared = HostStore.sharedCredential(in: hosts) else {
                choice = .none
                return
            }
            // A stale id — the credential was deleted from under these hosts —
            // is not something the Picker can show, and seeding it rendered
            // the popup BLANK. Treat it the way a mixed group is treated:
            // nothing picked yet.
            guard credentialStore.credential(for: shared) != nil else { return }
            choice = .credential(shared)
        }
        // The credential can be deleted (Settings → Credentials) while this
        // sheet is open. A Picker whose selection has no matching tag renders
        // BLANK, so the choice goes back to "Choose…" instead of showing an
        // empty popup that Apply would then refuse.
        .onChange(of: credentialStore.credentials) { _, _ in
            if case .credential(let id) = choice,
               credentialStore.credential(for: id) == nil {
                choice = .unset
            }
        }
    }

    private var group: HostGroup? {
        model.store.groups.first { $0.id == request.groupID }
    }

    private var groupName: String {
        group?.name ?? "—"
    }

    /// Serial and local entries are not part of this — a console has no
    /// credential — so the count the user is shown is SSH hosts only.
    private var sshCount: Int {
        group?.hosts.filter { $0.kind == .ssh }.count ?? 0
    }

    private var selectedCredential: Credential? {
        guard case .credential(let id) = choice else { return nil }
        return credentialStore.credential(for: id)
    }

    /// True when the group's SSH hosts do not agree about their credential.
    /// Then there is nothing to compare an Apply against, and the caption
    /// says so instead of pretending the group is on "None".
    private var isMixed: Bool {
        sshCount > 0 && !HostStore.credentialIsUniform(in: group?.hosts ?? [])
    }

    /// Says what Apply will do, including the username change: a credential's
    /// username travels with its password (see `HostStore.setCredential`), so
    /// the logins of every host in the group are about to change and that is
    /// not something to discover afterwards.
    private var effectDescription: String {
        guard sshCount > 0 else {
            // Apply is disabled here anyway; saying "Applies to 0 SSH hosts"
            // reads like a bug rather than an answer.
            return "There are no SSH hosts in this group."
        }
        let hosts = "\(sshCount) SSH host\(sshCount == 1 ? "" : "s")"
        if isMixed, choice == .unset {
            return "These \(hosts) use different credentials — pick one to apply to all."
        }
        guard let credential = selectedCredential else {
            return "Removes the credential from \(hosts) in this group; usernames are kept."
        }
        guard !credential.username.isEmpty else {
            return "Applies to \(hosts) in this group."
        }
        return "Applies to \(hosts) in this group. Their username becomes “\(credential.username)”."
    }

    private func apply() {
        // The group was deleted while this sheet was open: do nothing rather
        // than write a credential onto whatever group now holds that id. And
        // nothing picked is nothing to apply (the button is disabled then —
        // this is the belt to that brace).
        // Said out loud, not swallowed: a sheet that closes as though it had
        // worked, over a group that has been deleted, is how someone ends up
        // believing thirteen hosts were changed.
        guard group != nil else {
            dismiss()
            Self.explain("That group no longer exists.")
            return
        }
        // Nothing picked is nothing to apply (the button is disabled then —
        // this is the belt to that brace), and it needs no alert.
        guard choice != .unset else {
            dismiss()
            return
        }
        // The credential was deleted from under the sheet: applying would
        // write a reference to a Keychain entry that no longer exists, which
        // is worse than doing nothing.
        if case .credential = choice, selectedCredential == nil {
            dismiss()
            Self.explain("That credential no longer exists.")
            return
        }
        model.setGroupCredential(groupID: request.groupID, credential: selectedCredential)
        dismiss()
    }

    /// Deferred a turn like every other sheet-side alert: this runs while the
    /// sheet is still on screen, and an alert stacked on a sheet is a mess.
    private static func explain(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            // Short on purpose — see `NSAlert.sheepStyled` for the measured
            // point where the icon leaves the centre.
            alert.informativeText = "Nothing was changed."
            alert.addButton(withTitle: "OK")
            alert.sheepStyled().runModal()
        }
    }
}
