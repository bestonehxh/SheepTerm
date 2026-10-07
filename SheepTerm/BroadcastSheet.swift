import SwiftUI

/// Snippets → Broadcast to Tabs… (⌘⇧B): one line, typed into every ticked
/// SSH/serial tab. Deliberately a form with a Send button and not a mirror of
/// keystrokes — a slip here lands on every device at once, so each send is
/// one deliberate act with the targets visible. The plan is `BroadcastPlan`
/// (pure, harness-tested); this sheet only ticks and sends.
struct BroadcastSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var ticked: Set<UUID> = []
    @State private var lastReport: String?

    private var candidates: [BroadcastPlan.Candidate] {
        model.tabs.map { tab in
            let kind: ConnectionKind
            switch tab.content {
            case .local: kind = .local
            case .ssh: kind = .ssh
            case .serial: kind = .serial
            }
            return BroadcastPlan.Candidate(id: tab.id, title: tab.title, kind: kind, status: tab.statusInfo)
        }
    }

    private var eligible: [BroadcastPlan.Candidate] { BroadcastPlan.eligible(candidates) }

    private var plan: [(id: UUID, payload: String)] {
        BroadcastPlan.sends(text: text, to: ticked, among: candidates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Broadcast to Tabs")
                    .font(.headline)
                Text("Types one line, then Return, into every ticked tab. Only connected SSH and serial tabs are listed; local shells are not.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Command", text: $text, prompt: Text("show clock"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { if !plan.isEmpty { send() } }

            if eligible.isEmpty {
                Text("No connected SSH or serial tab to send to.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                HStack {
                    Button("Tick All") { ticked = Set(eligible.map(\.id)) }
                    Button("Tick None") { ticked.removeAll() }
                        .disabled(ticked.isEmpty)
                    Spacer()
                    Text("\(plan.count) of \(eligible.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                List {
                    ForEach(eligible, id: \.id) { tab in
                        Toggle(isOn: Binding(
                            get: { ticked.contains(tab.id) },
                            set: { on in if on { ticked.insert(tab.id) } else { ticked.remove(tab.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.title)
                                Text(tab.status ?? "")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(eligible.count) * 40 + 20, 240))
            }

            HStack {
                if let lastReport {
                    Text(lastReport)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send") { send() }
                    .disabled(plan.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheepSheetChrome()
    }

    private func send() {
        let sends = plan
        guard !sends.isEmpty else { return }
        let count = model.broadcast(sends)
        lastReport = "Sent to \(count) tab\(count == 1 ? "" : "s")"
    }
}
