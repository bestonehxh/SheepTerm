import SwiftUI

/// Tiny one-field prompt used for creating and renaming groups, and for
/// naming a section (the sub-heading inside a group). One field, one answer:
/// where a section goes is decided by the row it was opened from, never by a
/// second picker in here.
struct NamePromptSheet: View {
    let title: String
    let confirmLabel: String
    let onCommit: (String) -> Void

    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, confirmLabel: String = "Save", initialName: String = "",
         onCommit: @escaping (String) -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .sheepSheetChrome()
    }

    /// whitespacesAndNewlines, not whitespaces: a name pasted out of a
    /// spreadsheet cell carries the newline, which .whitespaces leaves in —
    /// and the group then draws as a two-line sidebar row.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
