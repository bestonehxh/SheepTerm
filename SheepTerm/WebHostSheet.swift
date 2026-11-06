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
    /// The switch's Jump segment (6.1).
    var jumpSwitch: Binding<Bool>? = nil

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

    init(mode: Mode, kindSwitch: Binding<ConnectionKind>? = nil, jumpSwitch: Binding<Bool>? = nil,
         prefill: (name: String, url: String)? = nil, groupName: String? = nil) {
        self.mode = mode
        self.kindSwitch = kindSwitch
        self.jumpSwitch = jumpSwitch
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
        var names = model.store.groupChoiceLabels
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
            if let kindSwitch { HostKindTabs(kind: kindSwitch, jump: jumpSwitch) }
            Form {
                HStack(spacing: 8) {
                    if kindSwitch != nil { HostKindSwitch(kind: .web) }
                    TextField("Name", text: $name, prompt: Text(isEditing ? "" : String(localized: "optional")))
                }
                .formRow("Name")
                TextField("URL", text: $url, prompt: Text(verbatim: "https://10.0.0.1"))
                    .formRow("URL")
                    .help("http:// or https:// — https:// is added when there is no scheme")
                if let urlProblem {
                    Text(urlProblem.localizedMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.destructive)
                }
                FormPopup(selection: $credentialSelection,
                          items: [.option(String(localized: "None"), nil)] + credentialStore.credentials.map {
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
                              items: groupNames.map { .option($0, $0) } + [.separator, .option(String(localized: "New group…"), Self.newGroupTag)])
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
        case .add: return String(localized: "Add")
        case .edit: return String(localized: "Save")
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

/// Add Host…: the SSH, telnet or web form, switched by the segmented
/// control at the top of each.
struct AddHostSheet: View {
    @State var kind: ConnectionKind
    var webPrefill: (name: String, url: String)? = nil
    /// Recent → Save as Host… on an SSH recent.
    var sshPrefill: Host? = nil
    /// The group the form starts in (a group's context menu → Add Host…).
    var groupName: String? = nil
    /// ＋ ▸ New Jump Server… opens it on Jump.
    var startsOnJump = false
    /// Reaches ▸ New Host…: the bastion the new host goes through.
    var jumpVia: UUID? = nil
    /// The Jump segment (6.1): the SSH form, saving a Jump Server.
    @State private var jump = false
    /// The SSH label picked in the badge menu (6.0 (35)): Server / Docker / Cloud.
    @State private var sshBadge: SSHBadge?
    @State private var jumpApplied = false

    var body: some View {
        form.environment(\.sshBadgeSwitch, $sshBadge)
    }

    @ViewBuilder private var form: some View {
        if kind == .web {
            WebHostSheet(mode: .add, kindSwitch: $kind, jumpSwitch: $jump, prefill: webPrefill, groupName: groupName)
        } else {
            // A fresh form per kind (`.id`): the telnet one starts on port 23.
            // SSH and Jump share one form (what is typed survives the switch).
            QuickConnectSheet(kind: kind == .telnet ? .telnet : .ssh, addOnly: true, kindSwitch: $kind, jumpSwitch: $jump,
                              initialGroup: groupName, prefill: sshPrefill?.kind == kind ? sshPrefill : nil,
                              initialJumpVia: kind == .ssh ? jumpVia : nil)
                .id(kind)
                // Once: back on SSH after Telnet is the user's SSH, not Jump again (Fable).
                .onAppear {
                    if startsOnJump, !jumpApplied { jump = true; jumpApplied = true }
                    // Recent ▸ Save as Host… keeps the recent's SRV / DCK / CLD (Fable round 2).
                    if sshBadge == nil, let badge = sshPrefill?.sshBadge, sshPrefill?.kind == kind { sshBadge = badge }
                    // …and its Jump Server flag (Fable round 3).
                    if !jumpApplied, sshPrefill?.isJumpServer == true, kind == .ssh { jump = true; jumpApplied = true }
                }
        }
    }
}
