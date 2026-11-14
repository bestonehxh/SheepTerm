import SwiftUI
import UniformTypeIdentifiers

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

/// The two heads over a workspace's fields — "Abbreviation" and "Name" — so
/// it is plain which box is which (6.1 (27), the owner: the abbreviation and
/// the full name are both the user's to type).
struct WorkspaceFieldHeads: View {
    static let codeWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 8) {
            Text("Abbreviation").frame(width: Self.codeWidth, alignment: .leading)
            Text("Name")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }
}

/// One workspace's two fields: the abbreviation the search field's chip
/// shows (at most `WorkspacePlan.shortLength` characters; left empty it is
/// made from the name, which is what the empty field shows), then its name.
struct WorkspaceFields: View {
    @Binding var name: String
    @Binding var code: String
    var onSubmit: () -> Void = {}

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 8) {
            TextField(trimmed.isEmpty ? "" : WorkspacePlan.short(trimmed), text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkspaceFieldHeads.codeWidth)
                .onSubmit(onSubmit)
                // No trimming while typing: it cut the text under a
                // Chinese or Japanese input method mid-composition (pinyin
                // longer than four letters could not be typed). The code is
                // cleaned where it is saved (`WorkspacePlan.cleanCode`).
                .accessibilityLabel("Abbreviation")
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSubmit)
        }
    }
}

/// Move to Workspace ▸ New Workspace… on a group: one new workspace, its
/// abbreviation and name.
struct WorkspaceNameSheet: View {
    let title: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    let onCommit: (String, String) -> Void

    @State private var name = ""
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).lineLimit(2).padding(.bottom, 6)
            WorkspaceFieldHeads()
            WorkspaceFields(name: $name, code: $code, onSubmit: commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 360)
        .sheepSheetChrome()
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        onCommit(trimmedName, code)
        dismiss()
    }
}

/// Manage Workspaces… (6.1 (27), the owner: New, Rename and Delete in ONE
/// place, in the middle of the window, not three lines of a menu): every
/// workspace as a row of its two fields, a bin to delete it (General has
/// none), + for a new one. Nothing changes until Save; Cancel leaves the
/// plan as it was. A deleted workspace's groups go back to General.
struct WorkspacesSheet: View {
    let plan: WorkspacePlan
    /// The rows, and the workspaces the sheet opened with (`WorkspacePlan.applying`).
    let onSave: ([WorkspacePlan.Draft], Set<UUID>) -> Void

    @State private var drafts: [WorkspacePlan.Draft]
    @State private var opened: Set<UUID>
    /// The row being dragged by its grip, to put the workspaces in order.
    @State private var dragged: UUID?
    @Environment(\.dismiss) private var dismiss

    init(plan: WorkspacePlan, onSave: @escaping ([WorkspacePlan.Draft], Set<UUID>) -> Void) {
        self.plan = plan
        self.onSave = onSave
        _drafts = State(initialValue: plan.drafts)
        _opened = State(initialValue: Set(plan.workspaces.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspaces").font(.headline).padding(.bottom, 6)
            WorkspaceFieldHeads()
                .padding(.leading, 24)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($drafts) { $draft in
                        HStack(spacing: 8) {
                            // The grip: drag a row up or down — the order
                            // here is the order of the list on the chip.
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 22)
                                .contentShape(Rectangle())
                                .onDrag {
                                    // (A drag that ended outside any row left the last id here: a new drag replaces it.)
                                    dragged = draft.id
                                    return NSItemProvider(object: draft.id.uuidString as NSString)
                                }
                                .help("Drag to Reorder")
                            WorkspaceFields(name: $draft.name, code: $draft.code)
                            Button {
                                drafts.removeAll { $0.id == draft.id }
                            } label: {
                                Image(systemName: "trash").frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Delete")
                            .accessibilityLabel("Delete")
                            // General is where every other group is: it stays.
                            .opacity(draft.id == WorkspacePlan.defaultID ? 0 : 1)
                            .disabled(draft.id == WorkspacePlan.defaultID)
                        }
                        .onDrop(of: [.plainText], delegate: WorkspaceRowDrop(target: draft.id, drafts: $drafts, dragged: $dragged))
                    }
                }
                .padding(1)
            }
            .frame(height: min(CGFloat(max(drafts.count, 1)) * 28 + 2, 230))
            HStack {
                Button {
                    drafts.append(.init(id: UUID(), name: "", code: ""))
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Workspace")
                .accessibilityLabel("New Workspace")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard plan.applying(drafts) != nil else { return }
                    onSave(drafts, opened)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.applying(drafts) == nil)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 400)
        .sheepSheetChrome()
    }
}

/// A row of Manage Workspaces… taking the dragged row's place as the drag
/// passes over it; the drop itself only ends the drag.
struct WorkspaceRowDrop: DropDelegate {
    let target: UUID
    @Binding var drafts: [WorkspacePlan.Draft]
    @Binding var dragged: UUID?

    /// Only a row's own grip starts a move: text dragged in from elsewhere
    /// finds no row in flight and is not taken.
    func validateDrop(info: DropInfo) -> Bool { dragged != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        drafts = WorkspacePlan.moved(drafts, dragged, onto: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
