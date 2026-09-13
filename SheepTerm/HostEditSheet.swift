import SwiftUI

/// Edits an existing host in place (right-click → Edit Host…).
struct HostEditSheet: View {
    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    /// It looked fine only because every interaction happened to touch some
    /// local @State as well.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    let original: Host

    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var credentialSelection: UUID?
    @State private var cipherMode: CipherMode
    @State private var agentForward: Bool
    @State private var vendor: Vendor
    @State private var baud: Int
    /// Whether the Port field has been typed in during this edit. See
    /// `parsedPort`.
    @State private var portEdited = false
    /// The same question for the Username field. See `effectiveUsername`.
    @State private var usernameEdited = false

    private static let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]
    /// Console ports on network gear are 9600 8N1 out of the box — Cisco,
    /// Aruba, Huawei and Juniper all ship that way.
    private static let defaultBaud = 9600
    /// The six common rates, plus this host's own if it is something else.
    /// A picker that cannot show the value it is editing is a picker that
    /// changes it.
    private var baudChoices: [Int] {
        Self.baudRates.contains(baud) ? Self.baudRates : (Self.baudRates + [baud]).sorted()
    }

    init(host: Host) {
        original = host
        _name = State(initialValue: host.name)
        _address = State(initialValue: host.address)
        _port = State(initialValue: String(host.port))
        _username = State(initialValue: host.username)
        _credentialSelection = State(initialValue: host.credentialID)
        _cipherMode = State(initialValue: host.cipherMode ?? .auto)
        _agentForward = State(initialValue: host.agentForward ?? false)
        _vendor = State(initialValue: host.highlightVendor)
        // A host whose stored baud is not one this picker offers showed a
        // BLANK picker, and Save wrote the bad value straight back, so the
        // advice "edit the host and pick a baud rate" led nowhere.
        //
        // The first fix fell back to 9600 whenever the value was not one of
        // the six offered — which quietly broke the hosts it was meant to
        // help. 1200 on old gear and 921600 on a modern USB-serial adapter are
        // perfectly good rates that `Host.serialBaudRange` accepts and this
        // picker does not list; opening the host to change its NAME rewrote
        // the baud to 9600 on save, and the next console session came up as
        // garbage. So the fallback now applies only to a value that is
        // genuinely unusable; anything inside the accepted range is kept and
        // shown (see `baudChoices`).
        let stored = host.kind == .serial ? host.port : Self.defaultBaud
        _baud = State(initialValue: Host.serialBaudRange.contains(stored) ? stored : Self.defaultBaud)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Host")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                if original.kind == .ssh {
                    TextField("Host / IP", text: $address)
                    if let addressError {
                        Text(addressError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    TextField("Port", text: $port)
                        .onChange(of: port) { portEdited = true }
                    if parsedPort == nil {
                        Text("Port must be 1-65535")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    Picker("Credential", selection: $credentialSelection) {
                        Text("None (enter manually)").tag(UUID?.none)
                        ForEach(model.credentialStore.credentials) { credential in
                            Text("\(credential.name) (\(credential.username))")
                                .tag(UUID?.some(credential.id))
                        }
                    }
                    if let credential = selectedCredential {
                        // Shown, not hidden. While this field was hidden the
                        // form saved the host's OLD username beside the NEW
                        // credential — a host called `admin` connecting as
                        // admin with auditor's password, because the password
                        // is looked up by credential id and the name came from
                        // the host. The two halves of one identity now travel
                        // together, and the name that will be saved is on
                        // screen while the choice is being made.
                        LabeledContent("Username") {
                            Text(effectiveUsername.isEmpty ? "—" : effectiveUsername)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        Text("Comes from “\(credential.name)” — a credential's username and its password are one login. Pick “None (enter manually)” to type a different name.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Username", text: $username)
                            .onChange(of: username) { usernameEdited = true }
                        RevealableSecureField(title: "Password", text: $password)
                        Text("Passwords live in the Keychain — filling this saves it as a new credential for this host.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Picker("Cipher mode", selection: $cipherMode) {
                        ForEach(CipherMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("Forward SSH agent", isOn: $agentForward)
                    Text("Lets this host use your local ssh-agent keys to hop onward. Only enable it for hosts you trust — root there can use the socket while you are connected.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if original.kind == .serial {
                    TextField("Device path", text: $address)
                    Picker("Baud rate", selection: $baud) {
                        ForEach(baudChoices, id: \.self) { rate in
                            Text(String(rate)).tag(rate)
                        }
                    }
                }
                Picker("Device family", selection: $vendor) {
                    ForEach(Vendor.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                Text("Picks the highlight rules. Auto colours only what every device shares — addresses, masks, MACs, VLAN ids, up/down. Naming the family adds its port names and reads its state words the way that platform means them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .sheepSheetChrome()
        .onAppear {
            // Only when this sheet can show a password field. Editing a
            // serial host is Name + Device path — taking the user's input
            // source away there just stops them naming a switch in Thai.
            guard original.kind == .ssh else { return }
            AuthPrompt.forceASCIIKeyboard()
        }
    }

    /// libssh takes the port as UInt32 — reject values it can't
    /// represent instead of trapping at connect time.
    private var parsedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        // A `:port` in the Host field stands in for an empty Port field, and
        // beats one the user has not touched — first touch wins, and keeps
        // winning, the same as `effectiveUsername`. `portEdited`, not "the
        // value still equals the original": someone who deliberately retypes
        // the port they already had should win, and comparing values cannot
        // tell that apart from never having touched the field.
        guard let value = Int(trimmed), (1...65535).contains(value) else {
            return trimmed.isEmpty ? splitAddress?.port : nil
        }
        if let fromAddress = splitAddress?.port, !portEdited { return fromAddress }
        return value
    }

    // Every field is trimmed of newlines as well as spaces: .whitespaces
    // alone keeps the newline a paste out of a spreadsheet cell carries, and
    // a name with one in it draws as a two-line sidebar row while a username
    // with one fails authentication looking identical to a good one.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Host field, split the way Quick Connect splits it. This comment
    /// used to say "same rule as ConnectParser" while the code below only
    /// looked for whitespace — two doors with different rules, exactly what
    /// the parser was introduced to stop. Pasting `10.0.0.1:2222` here saved
    /// that whole string as the address and every later connect failed as an
    /// unreadable DNS error.
    ///
    /// nil = the text is not a usable target; `addressError` names why.
    private var splitAddress: (host: String, port: Int?, user: String?)? {
        // SSH only. A serial device path is a PATH, and while `/dev/cu.*`
        // almost never carries an "@" or a ":", "almost never" is not a reason
        // to run a target parser over it.
        guard original.kind == .ssh else { return (trimmedAddress, nil, nil) }
        let raw = trimmedAddress
        // "@" belongs in this list too. Without it `admin@10.0.0.1` typed here
        // was saved whole as the address and could never connect, while the
        // Quick Connect box beside it took the same text apart — the last of
        // the "two doors, different rules" this parser exists to close.
        guard raw.contains(":") || raw.contains("[") || raw.contains("@") else {
            return (raw, nil, nil)
        }
        guard let parsed = ConnectParser.parse(raw, requireHostShape: false) else { return nil }
        return (parsed.address,
                parsed.port == 22 && !raw.hasSuffix(":22") ? nil : parsed.port,
                parsed.username.isEmpty ? nil : parsed.username)
    }

    /// The credential picked in the Credential row, when it still exists.
    /// A stale id (the credential was deleted from under this host) resolves
    /// to nil on purpose: the form then shows the manual Username/Password
    /// fields, which is the only thing left that can still name a login.
    private var selectedCredential: Credential? {
        model.credentialStore.credential(for: credentialSelection)
    }

    /// A chosen credential names its own user and its password is fetched by
    /// credential id — so the name has to come from the same place as the
    /// secret. Quick Connect has always done this (`selected.username`); this
    /// form stored the host's existing username instead, which is how a host
    /// called `admin` came to connect as admin with the auditor credential's
    /// password. The rules below only decide the MANUAL case.
    ///
    /// The field wins once the person has touched it AT ALL — first touch,
    /// not last. Touch Username, then paste `audit@switch.test` into Host, and
    /// the typed name still wins. That is deliberate: a paste must not quietly
    /// replace something typed by hand, and `parsedPort` behaves the same way,
    /// so the two fields cannot surprise in opposite directions. (An earlier
    /// note of mine called this "whichever was touched last", which is not what
    /// the code does.)
    ///
    /// Why the rule exists at all: this form is not Quick Connect. There the
    /// Username field starts EMPTY, so "the field wins" costs nothing. Here it
    /// arrives pre-filled with the host's current user, so "the field wins"
    /// meant pasting `audit@switch.test` saved `audit` nowhere at all: the
    /// address half was taken, the user half was dropped, and the host went on
    /// logging in as whoever it used to. A review measured exactly that.
    private var effectiveUsername: String {
        if let credential = selectedCredential, !credential.username.isEmpty {
            return credential.username
        }
        if usernameEdited { return trimmedUsername }
        if let fromAddress = splitAddress?.user { return fromAddress }
        return trimmedUsername
    }

    private var addressError: String? {
        guard original.kind == .ssh, !trimmedAddress.isEmpty else { return nil }
        if trimmedAddress.contains(where: { $0.isWhitespace }) { return "Host must not contain spaces" }
        // Word for word what Quick Connect says. Two forms that accept the same
        // text should also refuse it the same way.
        if trimmedAddress.hasSuffix("@") { return "Host is missing after the “@”" }
        guard splitAddress != nil else {
            return trimmedAddress.contains(":") ? "Port after “:” must be 1-65535"
                                                : "Host is not a valid address"
        }
        return nil
    }

    private var isValid: Bool {
        if trimmedName.isEmpty || trimmedAddress.isEmpty { return false }
        if original.kind == .ssh, parsedPort == nil || addressError != nil { return false }
        return true
    }

    private func save() {
        var host = original
        host.name = trimmedName
        // The host half only: a `:port` typed into this field belongs in the
        // Port field, not in the address libssh is handed.
        host.address = splitAddress?.host ?? trimmedAddress
        host.username = effectiveUsername
        // The literal, `.auto` included — same rule as Quick Connect since
        // `HostCompleteness` landed: a family written here is this host's
        // ANSWER, and only `nil` means "nobody ever said". Writing nil for
        // Auto would let the completion path in `Host.completed` hand this
        // host another entry's family the next time it is opened as a target.
        host.vendor = vendor
        switch original.kind {
        case .ssh:
            // isValid already guarantees a parsed in-range port; the
            // fallback only satisfies the compiler.
            host.port = parsedPort ?? 22
            // "None (enter manually)" writes nil, and on a SAVED host that nil
            // is an answer — the entry is a complete configuration, not a
            // target. It is honoured only if whoever opens it says
            // `HostCompleteness.complete`; opened as a target it can still be
            // handed the credential of another entry on the same endpoint.
            // See the note on `HostCompleteness` in Models.swift.
            host.credentialID = credentialSelection
            host.cipherMode = cipherMode
            host.agentForward = agentForward
            // `selectedCredential`, not `credentialSelection`: the same
            // question the form asked when it decided to show the password
            // field at all. A host pointing at a deleted credential shows it,
            // and a password typed there has to be saved, not dropped.
            if selectedCredential == nil, !password.isEmpty {
                // The trimmed username, like the host's: an untrimmed one
                // would be stored in the credential and inherited by every
                // host that later picks it.
                let credentialName = effectiveUsername.isEmpty
                    ? host.address : "\(effectiveUsername)@\(host.address)"
                let credential = model.credentialStore.add(
                    name: credentialName,
                    username: effectiveUsername,
                    password: password
                )
                host.credentialID = credential.id
            }
        case .serial:
            host.port = baud
        case .local:
            break
        }
        // The cached password belongs to the OLD user@address:port.
        if let old = model.store.groups.flatMap(\.hosts).first(where: { $0.id == host.id }) {
            model.forgetCachedPassword(for: old)
        }
        model.store.updateHost(host)
        dismiss()
    }
}
