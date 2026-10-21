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
    @State private var variablesRequest: SnippetVariablesRequest?

    private var candidates: [BroadcastPlan.Candidate] {
        model.tabs.map { tab in
            let kind: ConnectionKind
            switch tab.content {
            case .local: kind = .local
            case .ssh: kind = .ssh
            case .serial: kind = .serial
            case .web: kind = .web
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
                    // Split panes: the sessions side by side in the current tab.
                    if let panes = model.selectedWorkspace?.sessions, panes.count > 1 {
                        Button("Tick This Tab's Panes") {
                            ticked = Set(eligible.map(\.id)).intersection(panes)
                        }
                    }
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
                                Text(StatusInfoDisplay.text(tab.status) ?? "")
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
        .sheet(item: $variablesRequest) { request in
            SnippetVariablesSheet(request: request)
        }
    }

    private func send() {
        guard !plan.isEmpty else { return }
        // {{name}} / {{name=default}} in the line: ask once, then the same
        // text goes to every ticked tab. The template is the line that would
        // be sent (controls out, first line), not a later line of a paste.
        let line = SnippetCodec.commandText(text).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if SnippetVariables.hasPlaceholders(line) {
            let targets = ticked
            let tabs = candidates
            let model = model
            variablesRequest = SnippetVariablesRequest(title: String(localized: "Broadcast"), template: line) { filled in
                let sends = BroadcastPlan.sends(text: filled, to: targets, among: tabs)
                guard !sends.isEmpty, let confirmed = Self.confirmDangerous(filled, to: sends.map(\.id), model: model) else { return }
                let count = model.broadcast(sends, confirmed: confirmed)
                report(Self.sentReport(count))
            }
            return
        }
        let sends = plan
        guard let confirmed = Self.confirmDangerous(line, to: sends.map(\.id), model: model) else { return }
        let count = model.broadcast(sends, confirmed: confirmed)
        report(Self.sentReport(count))
    }

    private static func sentReport(_ count: Int) -> String {
        count == 1 ? String(localized: "Sent to 1 tab") : String(localized: "Sent to \(count) tabs")
    }

    /// Confirm Dangerous Commands, once for every ticked tab instead of a
    /// card in each: nil = the user cancelled; true = asked and confirmed
    /// (the tabs do not ask again); false = nothing to ask.
    /// Dangerous for ANY target's family counts (`shutdown` is only on the
    /// list for a Linux tab) — otherwise those tabs would each raise a card
    /// behind this sheet instead.
    private static func confirmDangerous(_ line: String, to ids: [UUID], model: AppModel) -> Bool? {
        let tabs = ids.count
        let vendors = Set(ids.map { id in model.tabs.first { $0.id == id }?.highlightVendor ?? .auto })
        guard model.confirmDangerousCommands,
              CommandGuard.isDangerous(line, anyOf: vendors.isEmpty ? [.auto] : vendors) else { return false }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = tabs == 1 ? String(localized: "Send to 1 tab?") : String(localized: "Send to \(tabs) tabs?")
        alert.informativeText = line
        alert.addButton(withTitle: String(localized: "Cancel"))   // default: Return cancels
        alert.addButton(withTitle: String(localized: "Send")).hasDestructiveAction = true
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn ? true : nil
    }

    private func report(_ text: String) { lastReport = text }
}
