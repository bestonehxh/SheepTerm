import SwiftUI

/// Tiny one-field prompt used for creating and renaming groups, and for
/// naming a section (the sub-heading inside a group). One field, one answer:
/// where a section goes is decided by the row it was opened from, never by a
/// second picker in here.
struct NamePromptSheet: View {
    let title: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    let onCommit: (String) -> Void
    /// New Group / Add Subgroup (6.0 (44), the user): the icon and colour are
    /// picked here too. nil = a plain name prompt (Rename…). The value is the
    /// level bar's colour for Auto.
    var iconAutoRGB: UInt32? = nil
    var onCommitWithIcon: ((String, GroupIcon?, GroupIconColor?) -> Void)? = nil

    @State private var name: String
    @State private var icon: GroupIcon?
    @State private var color: GroupIconColor?
    @Environment(\.dismiss) private var dismiss

    init(title: LocalizedStringKey, confirmLabel: LocalizedStringKey = "Save", initialName: String = "",
         onCommit: @escaping (String) -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    /// A group prompt with the icon picker under the name.
    init(title: LocalizedStringKey, confirmLabel: LocalizedStringKey, iconAutoRGB: UInt32,
         onCommit: @escaping (String, GroupIcon?, GroupIconColor?) -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onCommit = { _ in }
        self.iconAutoRGB = iconAutoRGB
        self.onCommitWithIcon = onCommit
        _name = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Two lines: a title can carry a group's name, however long.
            Text(title).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let icon, let auto = iconAutoRGB {
                    GroupIconView(icon: icon, size: 16, color: GroupIconSheet.color(color?.rgb ?? auto))
                }
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
            }
            if let auto = iconAutoRGB {
                GroupIconPicker(icon: $icon, color: $color, autoRGB: auto, cell: 28, columns: 8)
            }
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
        .frame(width: iconAutoRGB == nil ? 300 : 320)
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
        if let onCommitWithIcon { onCommitWithIcon(trimmed, icon, color) } else { onCommit(trimmed) }
        dismiss()
    }
}
