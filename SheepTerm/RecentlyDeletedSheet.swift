import SwiftUI

/// Recently Deleted (6.1 (28), `HostTrash`): what the user deleted in the
/// last 30 days — a host or a group with everything in it — each with the
/// day it goes for good, a button to put it back and one to delete it now.
/// Opened from the sidebar's ≡ menu.
struct RecentlyDeletedSheet: View {
    @ObservedObject var store: HostStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Deleted").font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.trash) { entry in
                        row(entry)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(height: 280)
            .background { ControlFill(zone: .sheet, cornerRadius: 6) }
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)) }
            HStack {
                Button("Delete All") {
                    if Self.confirmed(String(localized: "Delete All")) { store.emptyTrash() }
                }
                .disabled(store.trash.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheepSheetChrome()
    }

    private func row(_ entry: HostTrash.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isGroup ? "folder" : "terminal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if entry.isGroup {
                        Text("\(entry.hostCount) hosts").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Text(entry.host.map { entry.originPath.isEmpty ? $0.address : "\(entry.originPath) · \($0.address)" } ?? entry.originPath)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // The day it goes for good.
            Text(entry.deletedAt.addingTimeInterval(Double(HostTrash.days) * 86_400), format: .dateTime.day().month(.abbreviated))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            // (The store files a top-level group back in its own workspace.)
            Button { store.restoreFromTrash(entry.id) } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore")
            .accessibilityLabel("Restore")
            Button {
                if Self.confirmed(String(localized: "Delete Forever")) { store.emptyTrash(entry.id) }
            } label: {
                Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete Forever")
            .accessibilityLabel("Delete Forever")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    /// The one step here that cannot be taken back asks first — like every
    /// delete in the app: Cancel is the default, so Return never deletes.
    private static func confirmed(_ action: String) -> Bool {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = action
        alert.informativeText = String(localized: "This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: action)
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn
    }
}
