import SwiftUI

/// The "Port forwards" row of Edit Host and the SSH connect / Add Host form
/// (5.0 (49)–(50)). What is set, in plain words, one per line with a remove
/// button; then a + that opens a small form — Local / Remote / SOCKS and
/// plain fields, no ssh spelling to learn (the user: "make it easy"). The
/// listening port fills itself from the target's (443 → 8443); ssh's
/// spelling pasted into Host is taken apart. Rules: `ForwardDraft` (pure,
/// tested). Remote SOCKS is not offered here (rare); typed as `R1080` in a
/// pasted spec it still works.
struct PortForwardsRow: View {
    @Binding var forwards: [PortForwardSpec]
    /// The open add form; nil = closed.
    @Binding var draft: ForwardDraft?

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(forwards, id: \.self) { spec in
                    HStack(spacing: 4) {
                        Text(spec.displayLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        iconButton("minus.circle", help: "Remove this forward") {
                            forwards.removeAll { $0 == spec }
                        }
                    }
                }
                if draft != nil {
                    editor
                } else {
                    iconButton("plus.circle", help: "Add a port forward") {
                        draft = ForwardDraft()
                    }
                }
            }
            .frame(width: SheetLayout.fieldWidth, alignment: .leading)
        } label: {
            SheetLabel("Port forwards")
        }
        .help("Local: a port on this Mac reaches a host behind the server. Remote: a port on the server reaches a host this Mac can see. SOCKS: a proxy on this Mac for any host behind the server (set it in a browser). Open while the session is connected.")
        if let error = draft?.error(adding: forwards) {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(Theme.destructive)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Picker("", selection: field(\.kind, default: .local)) {
                    Text("Local").tag(ForwardDraft.Kind.local)
                    Text("Remote").tag(ForwardDraft.Kind.remote)
                    Text("SOCKS").tag(ForwardDraft.Kind.socks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                iconButton("checkmark.circle", help: "Add this forward") {
                    if let spec = draft?.addable(to: forwards) {
                        forwards.append(spec)
                        draft = nil
                    }
                }
                .disabled(draft?.addable(to: forwards) == nil)
                iconButton("xmark.circle", help: "Cancel") { draft = nil }
            }
            HStack(spacing: 4) {
                let kind = draft?.kind ?? .local
                TextField("Port", text: listenPortBinding, prompt: Text(verbatim: kind == .remote ? "9000" : kind == .socks ? "1080" : "8443"))
                    .labelsHidden()
                    .frame(width: 56)
                    .help(kind == .remote ? "Port on the server" : "Port on this Mac")
                if kind != .socks {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Host", text: hostBinding, prompt: Text(verbatim: kind == .remote ? "127.0.0.1" : "10.0.0.1"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .help(kind == .remote ? "A host this Mac can reach" : "A host the server can reach")
                    Text(verbatim: ":")
                        .foregroundStyle(.secondary)
                    TextField("Port", text: targetPortBinding, prompt: Text(verbatim: kind == .remote ? "3000" : "443"))
                        .labelsHidden()
                        .frame(width: 48)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func field<T>(_ path: WritableKeyPath<ForwardDraft, T>, default fallback: T) -> Binding<T> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }

    /// Typing here is the user's choice: the suggestion stops.
    private var listenPortBinding: Binding<String> {
        Binding(get: { draft?.listenPort ?? "" }, set: { value in
            guard value != draft?.listenPort else { return }
            draft?.listenPort = value
            draft?.listenPortEdited = true
        })
    }

    /// ssh's spelling pasted here fills the whole form.
    private var hostBinding: Binding<String> {
        Binding(get: { draft?.host ?? "" }, set: { value in
            guard value != draft?.host else { return }
            if draft?.absorbPasted(value) != true { draft?.host = value }
        })
    }

    private var targetPortBinding: Binding<String> {
        Binding(get: { draft?.targetPort ?? "" }, set: { value in
            guard value != draft?.targetPort else { return }
            draft?.targetPort = value
            draft?.targetPortChanged(avoiding: forwards)
        })
    }
}
