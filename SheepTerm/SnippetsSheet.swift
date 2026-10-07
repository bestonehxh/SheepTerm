import SwiftUI

/// Snippets → Edit Snippets…: the saved commands behind the Snippets menu.
/// Add at the bottom, edit in place, reorder with the arrows; every change is
/// written to snippets.json at once (`SnippetStore`).
struct SnippetsSheet: View {
    @ObservedObject private var store = AppModel.shared.snippetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text = ""
    @State private var sendReturn = true
    @State private var editing: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snippets")
                    .font(.headline)
                Text("Commands you send often. The Snippets menu types one into the current tab; a multi-line snippet goes through Safe Paste like any paste.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.snippets.isEmpty {
                Text("No snippets yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(store.snippets) { snippet in
                        row(snippet)
                    }
                }
                .frame(height: min(CGFloat(store.snippets.count) * 44 + 20, 240))
            }

            Divider()

            Text(editing == nil ? "Add Snippet" : "Edit “\(editing!.name)”")
                .font(.subheadline.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Interface summary"))
                TextField("Command", text: $text, prompt: Text("show interfaces status | include connected"), axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 12, design: .monospaced))
                Toggle("Press Return after it", isOn: $sendReturn)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                if editing != nil {
                    Button("Cancel Edit") { clearForm() }
                }
                Spacer()
                Button(editing == nil ? "Add" : "Save") { commit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheepSheetChrome()
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name)
                Text(snippet.text.replacingOccurrences(of: "\n", with: " ⏎ ") + (snippet.sendReturn ? " ⏎" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button { store.move(snippet, by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.snippets.first?.id == snippet.id)
                .help("Move up")
            Button { store.move(snippet, by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.snippets.last?.id == snippet.id)
                .help("Move down")
            Button { beginEdit(snippet) } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit")
            Button { store.remove(snippet); if editing?.id == snippet.id { clearForm() } } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete snippet")
        }
        .padding(.vertical, 2)
    }

    private func beginEdit(_ snippet: Snippet) {
        editing = snippet
        name = snippet.name
        text = snippet.text
        sendReturn = snippet.sendReturn
    }

    private func clearForm() {
        editing = nil
        name = ""
        text = ""
        sendReturn = true
    }

    private func commit() {
        if var snippet = editing {
            snippet.name = name
            snippet.text = text
            snippet.sendReturn = sendReturn
            store.update(snippet)
        } else {
            store.add(name: name, text: text, sendReturn: sendReturn)
        }
        clearForm()
    }
}
