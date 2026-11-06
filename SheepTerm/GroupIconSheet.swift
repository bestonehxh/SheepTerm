import SwiftUI

/// The icon grid ("—" = none) and the colour row (Auto = the level bar's).
/// One view for both doors (6.0 (44)): right-click a group ▸ Group Icon…,
/// and the New Group / Add Subgroup prompts.
struct GroupIconPicker: View {
    @Binding var icon: GroupIcon?
    @Binding var color: GroupIconColor?
    /// The level bar's colour — what Auto means here.
    let autoRGB: UInt32
    var cell: CGFloat = 32
    var columns = 8

    private var shownColor: Color { GroupIconSheet.color(color?.rgb ?? autoRGB) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 6), count: columns), spacing: 6) {
                tile(selected: icon == nil, help: String(localized: "No Icon")) {
                    Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
                } pick: { icon = nil }
                ForEach(GroupIcon.allCases) { item in
                    tile(selected: icon == item, help: item.rawValue.capitalized) {
                        GroupIconView(icon: item, size: cell * 0.47, color: icon == item ? shownColor : Color.primary.opacity(0.8))
                    } pick: { icon = item }
                }
            }
            HStack(spacing: 8) {
                swatch(nil)
                ForEach(GroupIconColor.allCases) { swatch($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private func tile<Content: View>(selected: Bool, help: String, @ViewBuilder content: () -> Content, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            content()
                .frame(width: cell, height: cell - 2)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? shownColor.opacity(0.28) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? shownColor.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// nil = Auto: the level bar's colour, drawn as a ring.
    private func swatch(_ value: GroupIconColor?) -> some View {
        let fill = GroupIconSheet.color(value?.rgb ?? autoRGB)
        return Button { color = value } label: {
            ZStack {
                if value == nil {
                    Circle().stroke(fill, lineWidth: 2).frame(width: 14, height: 14)
                } else {
                    Circle().fill(fill).frame(width: 16, height: 16)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.primary.opacity(color == value ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(value.map { $0.rawValue.capitalized } ?? String(localized: "Auto — the group's bar colour"))
    }
}

/// Right-click a group ▸ Group Icon… (6.1): each pick applies at once; Done closes.
struct GroupIconSheet: View {
    let group: HostGroup
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var icon: GroupIcon?
    @State private var color: GroupIconColor?

    init(group: HostGroup) {
        self.group = group
        _icon = State(initialValue: group.icon)
        _color = State(initialValue: group.iconColor)
    }

    private var autoRGB: UInt32 { GroupTree.levelColor(depth: max(1, GroupTree.depth(of: group.id, in: model.store.groups))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let icon { GroupIconView(icon: icon, size: 16, color: Self.color(color?.rgb ?? autoRGB)) }
                Text(group.name).font(.headline).lineLimit(1)
            }
            GroupIconPicker(icon: $icon, color: $color, autoRGB: autoRGB)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .sheepSheetChrome()
        // Esc closes it like every other sheet (Fable round 4).
        .onExitCommand { dismiss() }
        .onChange(of: icon) { _, _ in model.store.setIcon(icon, color: color, forGroup: group.id) }
        .onChange(of: color) { _, _ in model.store.setIcon(icon, color: color, forGroup: group.id) }
    }

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
