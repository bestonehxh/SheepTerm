import SwiftUI

/// A snippet (or broadcast line) with `{{placeholders}}` waiting for values.
/// `onSend` gets the final text; nothing is sent when the form is cancelled.
struct SnippetVariablesRequest: Identifiable {
    let id = UUID()
    let title: String
    let template: String
    let onSend: (String) -> Void
}

/// In-memory only: the last value typed for a variable name this run.
@MainActor
enum SnippetVariableMemory {
    static var last: [String: String] = [:]
}

/// Asks each variable once, shows the text that will go out, Send / Cancel.
/// One set of values: a broadcast uses it for every target.
struct SnippetVariablesSheet: View {
    let request: SnippetVariablesRequest
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]
    @FocusState private var focusedName: String?

    private var variables: [SnippetVariables.Variable] { SnippetVariables.variables(in: request.template) }

    private var errors: [String: String] {
        var out: [String: String] = [:]
        for (name, value) in values { if let e = SnippetVariables.error(for: value) { out[name] = e } }
        return out
    }

    private var preview: String { SnippetVariables.render(request.template, values: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.headline)
                .lineLimit(1)

            Form {
                ForEach(variables, id: \.name) { variable in
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(variable.name, text: binding(variable.name),
                                  prompt: Text(variable.defaultValue ?? ""))
                            .focused($focusedName, equals: variable.name)
                            .noAutoFill()
                            .onSubmit { send() }
                        if let error = errors[variable.name] {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.destructive)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("Will send")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 120)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .sheepSheetChrome()
        .onAppear {
            values = SnippetVariables.initialValues(for: request.template, remembered: SnippetVariableMemory.last)
            focusedName = variables.first?.name
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func send() {
        guard errors.isEmpty else { return }
        for variable in variables { SnippetVariableMemory.last[variable.name] = values[variable.name] ?? "" }
        let text = preview
        dismiss()
        DispatchQueue.main.async { request.onSend(text) }
    }
}
