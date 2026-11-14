import SwiftUI

/// Snippets → Broadcast to Tabs… (⌘⇧B): one line — or, since 6.1 (46),
/// several, each tab pacing them against its own device — typed into every
/// ticked SSH/serial tab. Deliberately a form with a Send button and not a mirror of
/// keystrokes — a slip here lands on every device at once, so each send is
/// one deliberate act with the targets visible. The plan is `BroadcastPlan`
/// (pure, harness-tested); this sheet only ticks and sends.
struct BroadcastSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String

    /// `text`: what the box starts with (the off-screen picture; empty in the app).
    init(text: String = "") { _text = State(initialValue: text) }
    @State private var ticked: Set<UUID> = []
    @State private var lastReport: String?
    @State private var variablesRequest: SnippetVariablesRequest?

    private var candidates: [BroadcastPlan.Candidate] {
        model.tabs.map { tab in
            let kind: ConnectionKind
            switch tab.content {
            case .local: kind = .local
            case .ssh: kind = .ssh
            case .serial(let c): kind = c.isTelnet ? .telnet : .serial
            case .web, .files, .ping: kind = .web
            }
            return BroadcastPlan.Candidate(id: tab.id, title: tab.title, kind: kind, status: tab.statusInfo)
        }
    }

    private var eligible: [BroadcastPlan.Candidate] { BroadcastPlan.eligible(candidates) }

    /// Eight lines of 12 pt monospaced text and the box's own padding.
    static let boxHeight: CGFloat = 8 * 15 + 14

    private var targets: [UUID] { BroadcastPlan.targets(ticked, among: candidates) }
    private var overLimit: Bool { !BroadcastPlan.withinLimits(BroadcastPlan.lines(text)) }
    private var canSend: Bool { !targets.isEmpty && !BroadcastPlan.lines(text).isEmpty && !overLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Broadcast to Tabs")
                    .font(.headline)
                Text("Types each line, then Return, into every ticked tab. Only connected SSH and serial tabs are listed; local shells are not.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A box of lines, like Safe Paste's review (6.1 (51), the owner:
            // "ช่องมีบรรทัดเดียว ทำแบบ Safe Paste ได้มั้ย"): Return is a new
            // line, ⌘Return (or the button) sends.
            ZStack(alignment: .topLeading) {
                CommandLinesView(text: $text, onCancel: { dismiss() })
                if text.isEmpty {
                    Text(verbatim: "show clock")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .frame(height: Self.boxHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

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
                    Text("\(targets.count) of \(eligible.count) selected")
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
                if overLimit {
                    Text("Safe Paste Limit")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else if let lastReport {
                    Text(lastReport)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
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
        guard canSend else { return }
        // {{name}} / {{name=default}} in the lines: ask once, then the same
        // text goes to every ticked tab. The template is what would be sent
        // (controls out, blank lines gone).
        let template = BroadcastPlan.lines(text).joined(separator: "\n")
        let targets = ticked
        let tabs = candidates
        let model = model
        if SnippetVariables.hasPlaceholders(template) {
            variablesRequest = SnippetVariablesRequest(title: String(localized: "Broadcast"), template: template) { filled in
                report(Self.dispatch(filled, to: targets, among: tabs, model: model))
            }
            return
        }
        report(Self.dispatch(template, to: targets, among: tabs, model: model))
    }

    /// One line: the old Send. Several: each tab paces them itself
    /// (`AppModel.broadcastLines`). nil = nothing went (cancelled, no target).
    private static func dispatch(_ text: String, to ticked: Set<UUID>, among tabs: [BroadcastPlan.Candidate], model: AppModel) -> String? {
        let lines = BroadcastPlan.lines(text)
        let ids = BroadcastPlan.targets(ticked, among: tabs)
        guard !lines.isEmpty, !ids.isEmpty, BroadcastPlan.withinLimits(lines),
              let confirmed = confirmDangerous(lines, to: ids, model: model) else { return nil }
        if lines.count == 1 {
            return sentReport(model.broadcast(BroadcastPlan.sends(text: lines[0], to: ticked, among: tabs), confirmed: confirmed))
        }
        return String(localized: "\(lines.count) lines") + " · " + sentReport(model.broadcastLines(lines, to: ids))
    }

    private static func sentReport(_ count: Int) -> String {
        String(localized: "Sent to \(count) tabs")
    }

    /// Danger Command Guard, once for every ticked tab instead of a
    /// card in each: nil = the user cancelled; true = asked and confirmed
    /// (the tabs do not ask again); false = nothing to ask.
    /// Dangerous for ANY target's family counts (`shutdown` is only on the
    /// list for a Linux tab) — otherwise those tabs would each raise a card
    /// behind this sheet instead.
    private static func confirmDangerous(_ lines: [String], to ids: [UUID], model: AppModel) -> Bool? {
        let tabs = ids.count
        let vendors = Set(ids.map { id in model.tabs.first { $0.id == id }?.highlightVendor ?? .auto })
        let families: Set<Vendor> = vendors.isEmpty ? [.auto] : vendors
        let risky = lines.filter { CommandGuard.isDangerous($0, anyOf: families) }
        guard model.confirmDangerousCommands, !risky.isEmpty else { return false }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Send to \(tabs) tabs?")
        alert.informativeText = risky.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Cancel"))   // default: Return cancels
        alert.addButton(withTitle: String(localized: "Send")).hasDestructiveAction = true
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn ? true : nil
    }

    private func report(_ text: String?) { if let text { lastReport = text } }
}

/// The Broadcast box: plain text exactly as typed (6.1 (52)). SwiftUI's
/// `TextEditor` is an NSTextView with the system's substitutions ON — it
/// turned `"uplink"` into curly quotes and `--force` into a dash on the way
/// to every ticked device — and it kept Esc for itself.
private struct CommandLinesView: NSViewRepresentable {
    @Binding var text: String
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 5
        Self.makePlain(textView)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scroll
    }

    /// Nothing between the keys and the device: no curly quotes, dashes,
    /// replacements, corrections, links or completions.
    static func makePlain(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        textView.string = text
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandLinesView
        weak var textView: NSTextView?

        init(_ parent: CommandLinesView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        /// Esc closes the sheet (the text view would open completions).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onCancel()
            return true
        }
    }
}
