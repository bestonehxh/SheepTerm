import SwiftUI

/// Groups-only list for easy drag reordering (no hosts in the way).
struct ReorderGroupsSheet: View {
    @ObservedObject var store: HostStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reorder Groups")
                .font(.headline)
            Text("Drag to change the order shown in the sidebar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            List {
                // The TOP-LEVEL groups (6.0 (12)): a subgroup is reordered by
                // dragging it in the sidebar, inside its parent.
                ForEach(GroupTree.children(of: nil, in: store.groups)) { group in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(group.name)
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(HostStore.hostCount(ofGroupIDs: [group.id], in: store.groups))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { from, to in
                    // The store's move, not a raw `groups.move`: the list
                    // holds subgroups between the rows shown here, and the
                    // offsets are positions among the top-level groups.
                    let tops = GroupTree.children(of: nil, in: store.groups)
                    store.moveGroups(withIDs: Set(from.map { tops[$0].id }), toParent: nil, atIndex: to)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320, height: 380)
        .sheepSheetChrome()
        // Esc closes it, as Esc closes any Mac sheet (Done holds Return).
        .onExitCommand { dismiss() }
    }
}
