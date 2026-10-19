import SwiftUI

/// The web host form (ConnectionKind.web): Add Host… with the Web kind picked
/// (also "Save as Host…" on a web tab, prefilled), and Edit Host… for a saved
/// web host. New Web Tab has no form — it opens an empty tab. Fields: Name, URL, Credential, Username
/// — nothing else (the user's rule: fewest fields, tooltips, short errors).
struct WebHostSheet: View {
    enum Mode {
        case add
        case edit(Host)
    }

    let mode: Mode
    /// Add Host…: the SSH | Web switch (nil elsewhere).
    var kindSwitch: Binding<ConnectionKind>? = nil

    @EnvironmentObject var model: AppModel
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var credentialSelection: UUID?
    @State private var groupSelection = WebHostSheet.defaultGroup
    @State private var newGroupName = ""

    private static let defaultGroup = "Quick Connect"
    private static let newGroupTag = "\u{0}new-group"

    init(mode: Mode, kindSwitch: Binding<ConnectionKind>? = nil, prefill: (name: String, url: String)? = nil,
         groupName: String? = nil) {
        self.mode = mode
        self.kindSwitch = kindSwitch
        if let groupName { _groupSelection = State(initialValue: groupName) }
        if let prefill {
            _name = State(initialValue: prefill.name)
            _url = State(initialValue: prefill.url)
        }
        if case .edit(let host) = mode {
            _name = State(initialValue: host.name)
            _url = State(initialValue: host.address)
            _username = State(initialValue: host.username)
            _credentialSelection = State(initialValue: host.credentialID.flatMap { id in
                AppModel.shared.credentialStore.credential(for: id) == nil ? nil : id
            })
        }
    }

    private var title: String {
        switch mode {
        case .add: return String(localized: "Add Host")
        case .edit: return String(localized: "Edit Host")
        }
    }

    private var groupNames: [String] {
        var names = model.store.groups.map(\.name)
        if !names.contains(Self.defaultGroup) { names.insert(Self.defaultGroup, at: 0) }
        return names
    }

    private var urlProblem: WebAddress.Problem? {
        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : WebAddress.problem(url)
    }

    private var isValid: Bool {
        guard case .success = WebAddress.normalize(url), WebAddress.problem(url) == nil else { return false }
        if case .edit = mode, ConfigurationHygiene.cleanedName(name).isEmpty { return false }
        return true
    }

    private var showsGroup: Bool {
        if case .add = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            if let kindSwitch {
                HostKindSwitch(kind: kindSwitch)
            }
            Form {
                TextField("Name", text: $name, prompt: Text(isEditing ? "" : "optional"))
                    .formRow("Name")
                TextField("URL", text: $url, prompt: Text(verbatim: "https://10.0.0.1"))
                    .formRow("URL")
                    .help("http:// or https:// — https:// is added when there is no scheme")
                if let urlProblem {
                    Text(urlProblem.message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.destructive)
                }
                FormPopup(selection: $credentialSelection,
                          items: [.option("None", nil)] + credentialStore.credentials.map {
                              .option("\($0.name) (\($0.username))", $0.id)
                          })
                .formRow("Credential")
                .help("Fill Login (the key in the tab's bar) types this login into the page — only on this host's own address, never submitted")
                if credentialSelection == nil {
                    TextField("Username", text: $username)
                        .formRow("Username")
                }
                if showsGroup {
                    FormPopup(selection: $groupSelection,
                              items: groupNames.map { .option($0, $0) } + [.separator, .option("New group…", Self.newGroupTag)])
                        .formRow("Group")
                    if groupSelection == Self.newGroupTag {
                        TextField("Group name", text: $newGroupName)
                            .formRow("Group name")
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: SheetLayout.width)
        .sheepSheetChrome()
        .noAutoFill()
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var confirmLabel: String {
        switch mode {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private var targetGroup: String {
        groupSelection == Self.newGroupTag ? HostStore.quickConnectGroupName(newGroupName) : groupSelection
    }

    /// The host this form describes (credential's user wins, the SSH rule).
    private func makeHost() -> Host? {
        let credential = credentialStore.credential(for: credentialSelection)
        let user = credential.map(\.username) ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        return Host.web(name: ConfigurationHygiene.cleanedName(name), url: url, username: user,
                        credentialID: credential?.id)
    }

    private func confirm() {
        guard var host = makeHost() else { return }
        switch mode {
        case .add:
            model.addHost(host, toGroupNamed: targetGroup)
        case .edit(let original):
            host.id = original.id
            host.section = original.section
            // The trusted certificate belongs to the server: kept while the
            // origin is the same, dropped when the URL points elsewhere.
            host.webTrustedCertSHA256 = WebAddress.sameOrigin(original.address, host.address)
                ? original.webTrustedCertSHA256 : nil
            model.store.updateHost(host)
        }
        dismiss()
    }
}

/// Add Host…: the SSH form or the web form, switched by the segmented
/// control at the top of either.
struct AddHostSheet: View {
    @State var kind: ConnectionKind
    var webPrefill: (name: String, url: String)? = nil
    /// Recent → Save as Host… on an SSH recent.
    var sshPrefill: Host? = nil
    /// The group the form starts in (a group's context menu → Add Host…).
    var groupName: String? = nil

    var body: some View {
        if kind == .web {
            WebHostSheet(mode: .add, kindSwitch: $kind, prefill: webPrefill, groupName: groupName)
        } else {
            QuickConnectSheet(kind: .ssh, addOnly: true, kindSwitch: $kind, initialGroup: groupName, prefill: sshPrefill)
        }
    }
}
