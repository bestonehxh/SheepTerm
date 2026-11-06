import SwiftUI

/// Help ▸ SheepTerm Guide (6.1): topics on the left, one page on the right —
/// a few steps and a real picture of the app in its window's edge (as in
/// What's New). Rules and text in `ManualPlan`.
struct ManualView: View {
    static let windowID = "guide"
    @State private var selection: String?

    init(topic: String? = nil) { _selection = State(initialValue: topic ?? ManualPlan.topics.first?.id) }

    private var topic: ManualPlan.Topic? { ManualPlan.topics.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle().fill(Theme.chromeLine).frame(width: 1)
            ScrollView {
                if let topic { page(topic).id(topic.id) }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.chrome)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ManualPlan.topics) { item in
                    let picked = item.id == selection
                    Button { selection = item.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 18)
                                .foregroundStyle(picked ? Theme.accent : Theme.dimText)
                            Text(LocalizedStringKey(item.title)).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(picked ? Theme.accent.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(10)
        }
        .frame(width: 240)
    }

    private func page(_ topic: ManualPlan.Topic) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(topic.title)).font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 18)
            if let picture = topic.picture {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                Image(picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.chromeLine, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .frame(maxWidth: 520, maxHeight: 340)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                    .accessibilityHidden(true)
            }
            if topic.id == "keys" {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(topic.steps, id: \.self) { line in
                        if let parts = ManualPlan.shortcutParts(line) {
                            GridRow {
                                Text(parts.keys).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.accent)
                                Text(LocalizedStringKey(parts.name)).font(.system(size: 13))
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.accent.opacity(0.15)))
                            Text(LocalizedStringKey(step)).font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
