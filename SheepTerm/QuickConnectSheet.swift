import Foundation
import SwiftUI

/// Form for ad-hoc SSH / Serial connections from the + menu.
/// Supports saved credentials (Keychain-backed), a target group picker,
/// and an optional "save session" toggle.
struct QuickConnectSheet: View {
    let kind: ConnectionKind

    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    /// It looked fine only because every interaction happened to touch some
    /// local @State as well.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    // Connection
    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"
    /// Whether the user touched the Port field. `parsedPort` lets a `:port`
    /// in the Host field win over the DEFAULT 22, not over a 22 the user
    /// typed back deliberately — the same `portEdited` rule HostEditSheet
    /// has; testing `value == 22` alone could not tell the two apart.
    @State private var portEdited = false

    // Credential
    @State private var credentialSelection: UUID?   // nil = enter manually
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredential = false
    @State private var credentialName = ""
    @State private var cipherMode: CipherMode = .auto
    @State private var agentForward = false
    /// Highlight device family. `.auto` leaves passive stream detection ON; a
    /// specific pick is a manual/saved choice, so detection is off for it.
    @State private var vendor: Vendor = .auto

    // Serial
    @State private var device = ""
    @State private var baud = Self.defaultBaud
    @State private var devices: [String] = []

    // Save session — off by default: Recent already remembers ad-hoc
    // connections; saving to a group is an explicit choice.
    @State private var saveSession = false
    @State private var groupSelection = QuickConnectSheet.defaultGroup
    @State private var newGroupName = ""
    @State private var saveLog = UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true

    private static let defaultGroup = "Quick Connect"
    private static let newGroupTag = "\u{0}new-group"
    private static let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]
    /// Console ports on network gear are 9600 8N1 out of the box — Cisco,
    /// Aruba, Huawei and Juniper all ship that way.
    private static let defaultBaud = 9600

    private var groupNames: [String] {
        var names = model.store.groups.map(\.name)
        if !names.contains(Self.defaultGroup) {
            names.insert(Self.defaultGroup, at: 0)
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .ssh ? "New SSH Connection" : "New Serial Console")
                .font(.headline)

            Form {
                if kind == .ssh {
                    TextField("Host / IP", text: $address, prompt: Text("10.10.1.1"))
                    if let addressError {
                        Text(addressError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    TextField("Port", text: $port, prompt: Text("22"))
                        .onChange(of: port) { portEdited = true }
                    if let portError {
                        Text(portError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }

                    Picker("Credential", selection: $credentialSelection) {
                        Text("Enter manually").tag(UUID?.none)
                        ForEach(model.credentialStore.credentials) { credential in
                            Text("\(credential.name) (\(credential.username))")
                                .tag(UUID?.some(credential.id))
                        }
                    }

                    if credentialSelection == nil {
                        TextField("Username", text: $username, prompt: Text("admin"))
                        RevealableSecureField(title: "Password", text: $password)
                        Toggle("Save as credential", isOn: $saveCredential)
                        if saveCredential {
                            TextField("Credential name", text: $credentialName,
                                      prompt: Text(defaultCredentialName))
                        }
                    }

                    Picker("Cipher mode", selection: $cipherMode) {
                        ForEach(CipherMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Picker("Device family", selection: $vendor) {
                        ForEach(Vendor.allCases) { family in
                            Text(family.label).tag(family)
                        }
                    }

                    Toggle("Forward SSH agent", isOn: $agentForward)

                    TextField("Session name (optional)", text: $name)
                } else {
                    HStack {
                        Picker("Device", selection: $device) {
                            if devices.isEmpty {
                                Text("No serial device found").tag("")
                            }
                            ForEach(devices, id: \.self) { path in
                                Text((path as NSString).lastPathComponent).tag(path)
                            }
                        }
                        Button {
                            devices = Self.serialDevices()
                            if !devices.contains(device) {
                                device = devices.first ?? ""
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13))
                                .frame(width: 30, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Rescan serial devices (plug the console cable into a powered switch first)")
                    }
                    Picker("Baud rate", selection: $baud) {
                        ForEach(Self.baudRates, id: \.self) { rate in
                            Text(String(rate)).tag(rate)
                        }
                    }
                    Picker("Device family", selection: $vendor) {
                        ForEach(Vendor.allCases) { family in
                            Text(family.label).tag(family)
                        }
                    }
                }

                Divider()

                if kind == .ssh {
                    Toggle("Save session to group", isOn: $saveSession)
                    if saveSession {
                        Picker("Group", selection: $groupSelection) {
                            ForEach(groupNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("New group…").tag(Self.newGroupTag)
                        }
                        if groupSelection == Self.newGroupTag {
                            TextField("Group name", text: $newGroupName, prompt: Text("Branch — BKK"))
                        }
                    }
                } else {
                    Toggle("Save session log", isOn: $saveLog)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            guard kind == .ssh else {
                // The serial form has no text field at all, so there is
                // nothing here to force a layout for — taking the user's
                // input source away would be pure loss.
                devices = Self.serialDevices()
                device = devices.first ?? ""
                return
            }
            // Switch to an English layout before any secure field grabs
            // focus — macOS blocks input-source switching during secure input.
            AuthPrompt.forceASCIIKeyboard()
        }
    }

    private var defaultCredentialName: String {
        effectiveUsername.isEmpty ? "credential" : "\(effectiveUsername)@\(targetHost)"
    }

    /// Address with surrounding whitespace/newlines stripped — pasted
    /// values often carry a trailing newline.
    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same reason as the address: a username pasted out of a runbook keeps
    /// its trailing space, and " admin" fails authentication while looking
    /// exactly like "admin" in the field — and it would be saved that way
    /// into the credential too.
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Username field wins; the `user@` half of the Host field is the
    /// fallback, so typing the whole target in one place does what it looks
    /// like it does.
    private var effectiveUsername: String {
        trimmedUsername.isEmpty ? (splitTarget?.user ?? "") : trimmedUsername
    }

    /// The Host field takes a whole target, not just a hostname: the sidebar's
    /// connect box has always accepted `user@host:port` and `[2001:db8::1]`,
    /// people type the same thing here out of habit, and a form that refuses
    /// what the box beside it accepts is just two doors with different rules.
    ///
    /// `ConnectParser` IS that rule — one parser, so the two entry points
    /// cannot drift. It splits at the last "@" (ssh's rule, so a UPN username
    /// survives), takes `:port` off the end, unwraps a bracketed IPv6 address
    /// and refuses whitespace anywhere. A plain hostname parses as itself.
    /// nil means "this text is not a target". The distinction matters: the
    /// first version of this fell back to the raw string whenever the parser
    /// said no, so `10.0.0.1:abc`, `h:99999` and a bare trailing colon all
    /// sailed through validation and were handed to libssh AS A HOSTNAME —
    /// producing a DNS error that says nothing about the port. The comment on
    /// `addressError` claimed those were caught; they were not.
    private var splitTarget: (user: String?, host: String, port: Int?)? {
        let raw = trimmedAddress
        guard raw.contains("@") || raw.contains(":") || raw.contains("[") else {
            return (nil, raw, nil)   // an ordinary hostname: nothing to take apart
        }
        // requireHostShape: false — in a Host field, `switch1:2222` is a host
        // and a port, not a search term.
        guard let parsed = ConnectParser.parse(raw, requireHostShape: false) else { return nil }
        return (parsed.username.isEmpty ? nil : parsed.username,
                parsed.address,
                parsed.port == 22 && !raw.hasSuffix(":22") ? nil : parsed.port)
    }

    /// What actually goes to libssh.
    /// The host half. When the target does not parse there is no host half
    /// — the raw text stands in so the field is not blanked while the user is
    /// still typing, and `addressError` is what refuses it.
    private var targetHost: String { splitTarget?.host ?? trimmedAddress }

    /// ConnectParser refuses whitespace ANYWHERE in a target and this form has
    /// to as well — trimming alone accepts "10.0.0.1 #core" (copied with its
    /// comment) and hands it over raw, where it comes back as a DNS error
    /// nobody can read. The check is on the HOST half, so the shorthand above
    /// still works.
    private var addressError: String? {
        guard kind == .ssh, !trimmedAddress.isEmpty else { return nil }
        // Kept ahead of the parser's own verdict: `admin@` is a specific
        // mistake with a specific answer, and letting it fall through to the
        // general "not a valid address" made the message worse than it was.
        if trimmedAddress.hasSuffix("@") { return "Host is missing after the “@”" }
        if targetHost.isEmpty { return "Host is missing after the “@”" }
        if targetHost.contains(where: { $0.isWhitespace }) { return "Host must not contain spaces" }
        // Everything ConnectParser refuses, refused here with a name. The test
        // is the parser itself, not a list of characters copied out of it —
        // that list was missing ":" and let a malformed port through.
        guard splitTarget != nil else {
            return trimmedAddress.contains(":") ? "Port after “:” must be 1-65535"
                                                : "Host is not a valid address"
        }
        if targetHost.contains("@") || targetHost.contains("[") || targetHost.contains("]") {
            return "Host is not a valid address"
        }
        return nil
    }

    /// libssh takes the port as UInt32 — reject values it can't
    /// represent instead of trapping at connect time.
    ///
    /// A port typed into the Host field (`10.0.0.1:2222`) wins over the Port
    /// field's default: pasting a full target and then being connected to 22
    /// is the kind of surprise that costs a session. An explicitly changed Port
    /// field still wins over that.
    private var parsedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty Port field with a port in the Host field is not an error:
        // `10.0.0.1:2222` carries everything needed, and Connect used to sit
        // there disabled saying "Port must be 1-65535" while the port the user
        // had typed was on screen in the field beside it.
        guard let value = Int(trimmed), (1...65535).contains(value) else {
            return trimmed.isEmpty ? splitTarget?.port : nil
        }
        if let fromTarget = splitTarget?.port, !portEdited { return fromTarget }
        return value
    }

    private var portError: String? {
        guard kind == .ssh, parsedPort == nil else { return nil }
        return "Port must be 1-65535"
    }

    private var isValid: Bool {
        switch kind {
        case .ssh:
            return parsedPort != nil && !targetHost.isEmpty && addressError == nil
        default: return !device.isEmpty
        }
    }

    private var targetGroup: String? {
        guard kind == .ssh, saveSession else { return nil }
        if groupSelection == Self.newGroupTag {
            // whitespacesAndNewlines, not whitespaces: a name pasted from a
            // spreadsheet cell carries the newline, which .whitespaces keeps
            // and the sidebar then draws as a two-line row.
            let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultGroup : trimmed
        }
        return groupSelection
    }

    /// Builds the host this form describes and opens it.
    ///
    /// Everything below is a `HostCompleteness.complete` host: every field on
    /// it is an answer, and the empty ones are answers too — "Enter manually"
    /// with no password means ASK ME, not "quietly use the credential saved
    /// against this address", and "Auto" means detect, even when a saved host
    /// on the same endpoint names a family. `AppModel.connectQuick` is the
    /// only consumer and opens with `.complete` for exactly that reason; if a
    /// second caller ever appears it has to say the same thing, or this form's
    /// two most visible choices go back to being silently overruled by
    /// hosts.json.
    private func connect() {
        var host: Host
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .ssh {
            var hostUsername = effectiveUsername
            var credentialID = credentialSelection

            if let selected = model.credentialStore.credential(for: credentialSelection) {
                hostUsername = selected.username
            } else if saveCredential, !password.isEmpty {
                // CredentialStore skips the Keychain write for an empty
                // password, which left the host bound to a credential that
                // could never authenticate and prompted on every connect.
                let typedName = credentialName.trimmingCharacters(in: .whitespacesAndNewlines)
                let credential = model.credentialStore.add(
                    name: typedName.isEmpty ? defaultCredentialName : typedName,
                    username: effectiveUsername,
                    password: password
                )
                credentialID = credential.id
            }

            host = Host(
                // A name of nothing but spaces is not a name — it would be
                // the tab title and the sidebar row.
                name: trimmedName.isEmpty ? targetHost : trimmedName,
                kind: .ssh,
                address: targetHost,
                // isValid already guarantees a parsed in-range port; the
                // fallback only satisfies the compiler.
                port: parsedPort ?? 22,
                username: hostUsername,
                credentialID: credentialID,
                cipherMode: cipherMode,
                agentForward: agentForward
            )
        } else {
            host = Host(
                name: (device as NSString).lastPathComponent,
                kind: .serial,
                address: device,
                port: baud
            )
        }
        // The picked value, `.auto` included — this form ANSWERED the
        // question, and `nil` is how a host says nobody asked it. `open`
        // already reads a literal `.auto` the way it reads nil for the
        // detection switch (`if let v = host.vendor, v != .auto`), so
        // detection still runs; what changes is that the answer survives
        // being written to a group or a recent, where nil would later be
        // read as a hole and filled from whatever saved host shares this
        // endpoint. HostEditSheet has always stored the literal — the two
        // doors now say the same thing.
        host.vendor = vendor
        // A password typed beside "Enter manually" is for THIS session (it is
        // saved only if "Save as credential" was ticked, and then the host
        // carries the id instead). Empty is not a hole to fill from the
        // Keychain: with `.complete` the nil credential stands, so SSHWorker
        // prompts — which is what "Enter manually" says on the label.
        let sessionPassword: String?
        if kind == .ssh, credentialSelection == nil, !password.isEmpty {
            sessionPassword = password
        } else {
            sessionPassword = nil
        }
        model.connectQuick(
            host: host,
            saveTo: targetGroup,
            password: sessionPassword,
            serialLog: kind == .serial ? saveLog : nil
        )
        dismiss()
    }

    private static func serialDevices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && $0 != "cu.Bluetooth-Incoming-Port" }
            .map { "/dev/" + $0 }
            .sorted()
    }
}
