import SwiftUI

/// The "Via jump host" row of Edit Host and Quick Connect (4.2 (9)): a field
/// the user types a bastion into (`user@host[:port]`) plus a menu of saved
/// SSH hosts that fills it.
///
/// Two values behind one field, so a saved choice stays a saved REFERENCE
/// (it follows the bastion's later edits and its credential):
///   • picking a saved host sets `jumpHostID` and shows its `user@address`;
///   • typing clears `jumpHostID` — the text is then the answer
///     (`Host.jumpSpec`);
///   • an empty field with no id = "None (direct)".
/// Validation lives in the sheets (`JumpTarget.parse`), next to their other
/// red error lines.
struct JumpHostRow: View {
    @Binding var text: String
    @Binding var jumpHostID: UUID?
    /// Saved hosts that may be a bastion (`JumpTarget.canBeBastion`).
    let candidates: [Host]
    /// How a saved host reads in the field (its login + endpoint).
    let render: (Host) -> String

    var body: some View {
        LabeledContent("Via jump host") {
            HStack(spacing: 4) {
                TextField("Via jump host", text: typed, prompt: Text("user@host"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                Menu {
                    Button("None (direct)") {
                        text = ""
                        jumpHostID = nil
                    }
                    if !candidates.isEmpty { Divider() }
                    ForEach(candidates) { candidate in
                        Button("\(candidate.name) (\(candidate.address))") {
                            text = render(candidate)
                            jumpHostID = candidate.id
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Pick a saved host")
                .accessibilityLabel("Saved jump hosts")
            }
        }
        .help("Logs into this host first and tunnels the connection through it (ProxyJump). Type user@host[:port] or pick a saved host; empty = direct. The jump host needs TCP forwarding allowed.")
    }

    /// The field's binding: a real edit turns a saved reference into typed
    /// text. Compared first, because AppKit can write the same string back
    /// when the field merely loses focus, and that must not drop the id.
    private var typed: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard newValue != text else { return }
                text = newValue
                jumpHostID = nil
            }
        )
    }
}

extension JumpHostRow {
    /// A saved bastion as the field shows it: the login it connects with (its
    /// credential's username wins, as in `AppModel.open`) and its endpoint.
    static func text(for host: Host, credentials: CredentialStore) -> String {
        var username = host.username
        if let credential = credentials.credential(for: host.credentialID), !credential.username.isEmpty {
            username = credential.username
        }
        return JumpTarget.text(address: host.address, port: host.port, username: username)
    }
}
