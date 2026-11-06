import SwiftUI

/// Add / Edit Host ▸ Authentication (6.1): how an SSH host logs in.
struct AuthMethodRow: View {
    @Binding var method: SSHAuthMethod

    var body: some View {
        FormPopup(selection: $method, items: SSHAuthMethod.allCases.map { .option($0.label, $0) })
            .formRow("Authentication")
            .help("Automatic tries the credential's key, the ssh-agent, ~/.ssh keys, then the password.")
    }

    /// The credentials the Credential popup offers for `method`: only those
    /// with a key for Key; every one otherwise.
    static func credentials(_ all: [Credential], for method: SSHAuthMethod) -> [Credential] {
        method == .key ? all.filter { $0.publicKey != nil } : all
    }
}

/// Chips left to right, onto the next line when the width runs out.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let item = (index: i, size: CGSize(width: min(size.width, width), height: size.height))
            if x > 0, x + item.size.width > width {
                rows.append([]); x = 0
            }
            rows[rows.count - 1].append(item)
            x += item.size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        let lines = rows(width, subviews)
        let height = lines.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(bounds.width, subviews) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), anchor: .topLeading,
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

/// A Jump Server's Reaches row (6.1): the groups whose hosts connect through
/// it, as removable chips and a ＋ menu of the others. Subgroups follow their
/// group, so only what is picked is shown.
struct ReachesRow: View {
    @Binding var reaches: Set<UUID>
    let groups: [HostGroup]
    /// ＋ ▸ New Host… (6.0 (28)): one host behind this server, typed in the
    /// Add Host that opens after this one is saved.
    @Binding var addBehind: Bool

    var body: some View {
        LabeledContent {
            // Wraps onto more lines (Fable round 4: 3–4 groups in one HStack
            // cut every name to "…" and pushed the ＋ out of reach).
            ChipFlowLayout(spacing: 6) {
                ForEach(picked) { group in
                    HStack(spacing: 3) {
                        Text(group.name).font(.system(size: 11)).lineLimit(1)
                        Button { reaches.remove(group.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop reaching this group")
                        .accessibilityLabel("Stop reaching this group")
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.controlFill))
                }
                if addBehind {
                    HStack(spacing: 3) {
                        Text("New Host").font(.system(size: 11)).lineLimit(1)
                        Button { addBehind = false } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.controlFill))
                    .help("After Add, a new host is added behind this Jump Server")
                }
                do {
                    Menu {
                        ForEach(others) { group in
                            Button(path(of: group)) { reaches.insert(group.id) }
                        }
                        if !others.isEmpty { Divider() }
                        Button("New Host…") { addBehind = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Hosts in these groups connect through this Jump Server")
                    .accessibilityLabel("Reaches")
                }
            }
            .frame(width: SheetLayout.fieldWidth, alignment: .leading)
        } label: {
            SheetLabel("Reaches")
        }
    }

    private var picked: [HostGroup] { groups.filter { reaches.contains($0.id) } }
    private var others: [HostGroup] { groups.filter { !reaches.contains($0.id) } }

    /// "Head Office / Building A" — a subgroup named with its parents.
    private func path(of group: HostGroup) -> String {
        var names = [group.name]
        var current = group
        var seen: Set<UUID> = [group.id]
        while let parentID = current.parentID, let parent = groups.first(where: { $0.id == parentID }),
              seen.insert(parent.id).inserted {
            names.insert(parent.name, at: 0)
            current = parent
        }
        return names.joined(separator: " / ")
    }
}
