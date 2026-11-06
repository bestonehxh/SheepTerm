import SwiftUI

/// Adding Hosts (6.1; shown once on a Mac with no saved host — out of Help since 6.1 (2)): one sheet, six small pictures — every way to
/// add a host and where it opens from. The pictures are drawn from the app's
/// own colours (no screenshots to go stale). Also shown once on a launch with
/// no saved host (`AddingHostsSheet.shownKey`).
struct AddingHostsSheet: View {
    static let shownKey = "addingHostsShown"
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AddingHostsSheet.shownKey) private var shownOnce = false

    private struct Way: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let menuTitle: String
        let items: [String]
        let lit: Int
    }

    private var ways: [Way] {
        [
            Way(id: 0, title: "Hosts menu — ⌘N", menuTitle: String(localized: "Hosts"),
                items: [String(localized: "Add Host…"), String(localized: "Add Hosts…"), String(localized: "New Group")], lit: 0),
            Way(id: 1, title: "≡ at the bottom of the sidebar", menuTitle: "≡",
                items: [String(localized: "Add Host…"), String(localized: "Add Hosts…"), String(localized: "New Group")], lit: 0),
            Way(id: 2, title: "Right-click a group, a host or empty space", menuTitle: String(localized: "Data Center"),
                items: [String(localized: "Add Host…"), String(localized: "Add Hosts…"), String(localized: "Add Subgroup…")], lit: 0),
            Way(id: 3, title: "Type user@host, then Save as Host", menuTitle: "netadmin@10.20.5.2",
                items: [String(localized: "Connect"), String(localized: "Save as Host…")], lit: 1),
            Way(id: 4, title: "Add Hosts… — paste a list, groups by path", menuTitle: String(localized: "Add Hosts"),
                items: ["Core/Floor 4, CX-A4-01, 10.20.4.11", "Branch South, SRX-South, 198.51.100.9"], lit: -1),
            Way(id: 5, title: "Import a group file or a link", menuTitle: String(localized: "Import"),
                items: [String(localized: "Import Group…"), String(localized: "Import from Link…"), String(localized: "Import Hosts File…")], lit: 0),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adding Hosts").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ways) { way in card(way) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .sheepSheetChrome()
        // Esc closes it like every other sheet (Fable round 4).
        .onExitCommand { dismiss() }
        .onAppear { shownOnce = true }
    }

    private func card(_ way: Way) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            picture(way)
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tabActive))
            Text(way.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A small menu (or list) as the app draws it, the item to pick lit.
    private func picture(_ way: Way) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(way.menuTitle)
                .font(.system(size: 10, weight: .semibold, design: way.lit < 0 ? .default : .default))
                .foregroundStyle(Theme.dimText)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(Array(way.items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(.system(size: way.lit < 0 ? 9 : 10, design: way.lit < 0 ? .monospaced : .default))
                    .lineLimit(1)
                    .foregroundStyle(index == way.lit ? Color.white : Color.primary.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(index == way.lit ? Theme.accent : Color.clear))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))
        .padding(10)
    }
}
