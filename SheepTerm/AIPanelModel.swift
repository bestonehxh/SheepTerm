import AppKit
import Combine
import SheepVT
import SheepVTRender
import SwiftUI

/// AI panel state (ARCHITECTURE.md "AI panel"). One conversation per
/// terminal session, in memory only — a closed session drops its
/// conversation, and nothing here is written to disk (the vendor CLI keeps
/// its own transcript, as it does for any use of it).
///
/// The AI only SUGGESTS: the one way text reaches a session is the user's
/// "Paste into Tab", through the normal paste path (Safe Paste applies) and
/// never with a Return.

/// Shown / width of the panel, on their own: the menu commands, the tab-bar
/// button and the column observe THIS, so a streamed delta (which changes
/// `AIPanelModel.conversations`) does not re-evaluate them.
@MainActor
final class AIPanelChrome: ObservableObject {
    static let shared = AIPanelChrome()

    @Published var shown: Bool {
        didSet { UserDefaults.standard.set(shown, forKey: AIPanelModel.shownKey) }
    }
    /// Persisted by the resize handle when a drag ends.
    @Published var width: CGFloat

    private init() {
        let defaults = UserDefaults.standard
        shown = defaults.bool(forKey: AIPanelModel.shownKey)
        let saved = defaults.double(forKey: AIPanelModel.widthKey)
        width = saved == 0 ? 360 : min(max(saved, AIPanelModel.widthRange.lowerBound), AIPanelModel.widthRange.upperBound)
    }

    /// Slides like the left sidebar (the user: the two must feel the same).
    func toggle() {
        withAnimation(AppModel.sidebarAnimation) { shown.toggle() }
        if !shown { AppModel.shared.focusActiveTerminal() }
    }
}

@MainActor
final class AIPanelModel: ObservableObject {
    static let shared = AIPanelModel()

    static let shownKey = "aiPanelShown"
    static let widthKey = "aiPanelWidth"
    static let providerKey = "aiDefaultProvider"
    static let claudeModelKey = "aiClaudeModel"
    static let chatGPTModelKey = "aiChatGPTModel"
    static let geminiModelKey = "aiGeminiModel"
    static let widthRange: ClosedRange<CGFloat> = 280...640

    @Published private(set) var conversations: [UUID: AIConversation] = [:]
    @Published private(set) var status: [AIProvider: AIAccountStatus] = [:]
    /// The chosen model per provider (persisted; the header menu and Settings
    /// observe this so both stay in step).
    @Published private(set) var models: [AIProvider: String] = [:]
    @Published private(set) var checking = false

    private var runs = AIRunBook<AIProcessRun>()
    private var deltas = AIDeltaBuffer()
    /// Providers whose login was confirmed this launch (checked once before
    /// the first send, so a signed-out CLI gets the actionable line).
    private var verified: Set<AIProvider> = []
    private var binaries: [AIProvider: AIBinary] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// For `AIPanelAutoClose`: how many tabs the last `$tabs` value had.
    private var tabCount = 0

    private init() {
        AppModel.shared.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.prune(keeping: Set(tabs.map(\.id)))
                let chrome = AIPanelChrome.shared
                if AIPanelAutoClose.shouldHide(tabsBefore: self.tabCount, tabsAfter: tabs.count, shown: chrome.shown) {
                    withAnimation(AppModel.sidebarAnimation) { chrome.shown = false }
                }
                self.tabCount = tabs.count
            }
            .store(in: &cancellables)
        for provider in AIProvider.allCases {
            let stored = UserDefaults.standard.string(forKey: Self.modelKey(for: provider)) ?? AICLI.defaultModel(for: provider)
            models[provider] = AICLI.model(stored, for: provider)
        }
        #if DEBUG
        AIPanelDemo.runIfRequested(self)
        #endif
    }

    var defaultProvider: AIProvider {
        UserDefaults.standard.string(forKey: Self.providerKey).flatMap(AIProvider.init(rawValue:)) ?? .claude
    }

    /// The provider's chosen model (persisted; never an unknown value).
    func model(for provider: AIProvider) -> String {
        models[provider] ?? AICLI.defaultModel(for: provider)
    }

    func setModel(_ model: String, for provider: AIProvider) {
        let value = AICLI.model(model, for: provider)
        guard models[provider] != value else { return }
        models[provider] = value
        UserDefaults.standard.set(value, forKey: Self.modelKey(for: provider))
    }

    static func modelKey(for provider: AIProvider) -> String {
        switch provider {
        case .claude: return claudeModelKey
        case .chatgpt: return chatGPTModelKey
        case .gemini: return geminiModelKey
        }
    }

    func toggle() { AIPanelChrome.shared.toggle() }

    // MARK: Conversations

    func conversation(for session: UUID) -> AIConversation {
        conversations[session] ?? AIConversation(provider: defaultProvider)
    }

    private func update(_ session: UUID, _ change: (inout AIConversation) -> Void) {
        var c = conversation(for: session)
        change(&c)
        conversations[session] = c
    }

    private func prune(keeping live: Set<UUID>) {
        for id in conversations.keys where !live.contains(id) {
            runs.remove(id)?.cancel()
            deltas.drop(id)
            conversations.removeValue(forKey: id)
        }
    }

    func setDraft(_ text: String, for session: UUID) {
        guard conversation(for: session).draft != text else { return }
        update(session) { $0.draft = text }
    }

    func newChat(for session: UUID) {
        runs.remove(session)?.cancel()
        deltas.drop(session)
        let provider = conversation(for: session).provider
        conversations[session] = AIConversation(provider: provider)
    }

    /// A different provider starts a new conversation: the other CLI has
    /// none of this one's context.
    func setProvider(_ provider: AIProvider, for session: UUID) {
        guard conversation(for: session).provider != provider else { return }
        runs.remove(session)?.cancel()
        deltas.drop(session)
        conversations[session] = conversation(for: session).switchingProvider(to: provider)
    }

    // MARK: Attachments

    func attachSelection(for session: UUID) {
        guard let view = AppModel.shared.terminalHost(ofSession: session)?.terminalView, view.hasSelection else {
            NSSound.beep(); return
        }
        attach(view.selectedText, title: "Selection", to: session)
    }

    func attachTail(for session: UUID) {
        guard let view = AppModel.shared.terminalHost(ofSession: session)?.terminalView else { NSSound.beep(); return }
        // LOGICAL lines (soft wraps joined): masking is per line, so a
        // secret cut at the screen width would leave its tail in the clear.
        // Only the tail is built.
        let tail = view.terminal.logicalTail(limit: AIPromptBuilder.tailLines)
        let outcome = AITailSelector.select(lines: tail.lines, startRows: tail.startRows, cols: tail.cols,
                                            alternate: tail.alternate, mark: conversation(for: session).attachMark)
        switch outcome {
        case .empty:
            NSSound.beep()
        case .nothingNew:
            showNotice(String(localized: "No new output since the last attach"), for: session)
        case .recent(let lines, let mark):
            update(session) { $0.attachMark = mark; $0.notice = nil }
            attach(lines.joined(separator: "\n"), title: "Last \(lines.count) lines", to: session)
        case .new(let lines, let mark):
            update(session) { $0.attachMark = mark; $0.notice = nil }
            attach(lines.joined(separator: "\n"), title: "New output · \(lines.count) lines", to: session)
        }
    }

    private func showNotice(_ text: String, for session: UUID) {
        update(session) { $0.notice = text }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.conversation(for: session).notice == text else { return }
            self.update(session) { $0.notice = nil }
        }
    }

    /// Masking a long selection is not free: it runs off main and the chip
    /// appears when it is done (if the conversation is still there).
    private func attach(_ raw: String, title: String, to session: UUID) {
        let known = knownSecrets(for: session)
        // The chat it was attached to: a New Chat while masking runs must not
        // receive it.
        let epoch = AIAttachBook.begin(&conversations, session: session, defaultProvider: defaultProvider)
        Task.detached(priority: .userInitiated) {
            let attachment = AIAttachment.masked(raw, title: title, knownSecrets: known)
            await MainActor.run {
                let model = AIPanelModel.shared
                guard AppModel.shared.tabs.contains(where: { $0.id == session }) else { return }
                AIAttachBook.land(attachment, session: session, epoch: epoch, in: &model.conversations)
            }
        }
    }

    func removeAttachment(_ id: UUID, from session: UUID) {
        update(session) { $0.pending.removeAll { $0.id == id } }
    }

    /// A pasted image joins the composer as a chip. The bytes stay in memory;
    /// the run's own folder is where they land on disk, for the length of the
    /// run (see `AIRunPlanner`).
    func attachImage(_ pngData: Data, for session: UUID) {
        guard !pngData.isEmpty else { NSSound.beep(); return }
        guard AppModel.shared.tabs.contains(where: { $0.id == session }) else { return }
        let name = "pasted-\(UUID().uuidString.prefix(8).lowercased()).png"
        let image = AIImageAttachment(pngData: pngData, name: name)
        let epoch = AIAttachBook.begin(&conversations, session: session, defaultProvider: defaultProvider)
        _ = AIAttachBook.landImage(image, session: session, epoch: epoch, in: &conversations)
    }

    /// The tab's terminal exactly as it is on screen, as an image chip. Unlike
    /// a text attach this cannot be masked — what is on screen is sent.
    func captureTerminal(for session: UUID) {
        guard let png = AppModel.shared.terminalHost(ofSession: session)?.terminalView.snapshotPNG() else {
            showNotice(String(localized: "Nothing on screen to capture"), for: session); return
        }
        attachImage(png, for: session)
    }

    func removeImage(_ id: UUID, from session: UUID) {
        update(session) { $0.pendingImages.removeAll { $0.id == id } }
    }

    /// The saved credential's password for this session, if the vault is
    /// already open (never a Keychain prompt for this).
    private func knownSecrets(for session: UUID) -> [String] {
        guard let tab = AppModel.shared.tabs.first(where: { $0.id == session }) else { return [] }
        let host: Host?
        switch tab.content {
        case .ssh(let c): host = c.host
        case .serial(let c): host = c.host
        case .web(let c): host = c.host
        case .local: host = nil
        }
        guard let id = host?.credentialID, let password = Keychain.passwordWithoutPrompt(for: id) else { return [] }
        return [password]
    }

    /// Device family and session kind for the system prompt.
    private func context(for session: UUID) -> (family: String, kind: String) {
        guard let tab = AppModel.shared.tabs.first(where: { $0.id == session }) else { return ("unknown", "terminal") }
        let family = tab.highlightVendor == .auto ? "not set — infer it from the output" : tab.highlightVendor.label
        switch tab.content {
        case .ssh: return (family, "SSH")
        case .serial: return (family, "serial console")
        case .local: return ("macOS (local shell on the engineer's Mac)", "local shell")
        case .web: return ("a device's web interface (no terminal output)", "web page")
        }
    }

    // MARK: Sending

    func canSend(_ session: UUID) -> Bool {
        let c = conversation(for: session)
        return !c.running && (!c.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !c.pending.isEmpty || !c.pendingImages.isEmpty)
    }

    func send(for session: UUID) {
        guard canSend(session) else { return }
        let c = conversation(for: session)
        let provider = c.provider
        let question = c.draft
        let attachments = c.pending
        let images = c.pendingImages
        let context = context(for: session)
        let system = AIPromptBuilder.systemPrompt(family: context.family, sessionKind: context.kind)
        let user = AIPromptBuilder.userPrompt(question: question, attachments: attachments,
                                              imageNames: images.map(\.name))
        let turn = UUID()
        update(session) {
            $0.turn = turn
            $0.messages.append(AIMessage(role: .user, text: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                         provider: provider, attachments: attachments, images: images))
            $0.messages.append(AIMessage(role: .assistant, text: "", provider: provider))
            $0.pending = []
            $0.pendingImages = []
            $0.draft = ""
            $0.running = true
        }
        let claudeSession = c.claudeSession.uuidString.lowercased()
        let claudeResume = c.claudeStarted
        let codexThread = c.codexThread
        let geminiSession = c.geminiSession
        let geminiResume = geminiSession != nil
        let model = model(for: provider)
        let needsCheck = !verified.contains(provider)
        let known = binaries[provider]

        Task.detached(priority: .userInitiated) {
            let env = ProcessInfo.processInfo.environment
            let binary = known ?? AIBinaryLocator.locate(provider, environment: env)
            var planner = AIRunPlanner(root: AIRunPlanner.defaultRoot(), baseEnvironment: env,
                                       loginPath: AIBinaryLocator.loginPath(environment: env))
            planner.sandboxCodex = true
            planner.sandboxGemini = true
            let outcome = AIRunPrep.prepare(provider, binary: binary, needsCheck: needsCheck, planner: planner) { planner, binary in
                switch provider {
                case .claude:
                    return try planner.claudeSpec(binary: binary, system: system, prompt: user, model: model,
                                                  sessionID: claudeSession, resume: claudeResume, images: images)
                case .chatgpt:
                    let prompt = codexThread == nil ? AIPromptBuilder.combined(system: system, user: user) : user
                    return try planner.codexSpec(binary: binary, prompt: prompt, threadID: codexThread,
                                                 model: model, images: images)
                case .gemini:
                    return try planner.geminiSpec(binary: binary, system: system, prompt: user, model: model,
                                                  sessionID: geminiSession, resume: geminiResume, images: images)
                }
            }
            await self.prepared(outcome, provider: provider, session: session, turn: turn)
        }
    }

    /// Every result of the pre-start work lands here, and only on the turn
    /// that asked for it: after New Chat + a new send, an old "not signed
    /// in" must not end the new turn's stream.
    private func prepared(_ outcome: AIRunPrep.Outcome, provider: AIProvider, session: UUID, turn: UUID) {
        guard conversations[session]?.isCurrent(turn: turn) == true else {
            if case .ready(_, let spec) = outcome { for path in spec.cleanup { try? FileManager.default.removeItem(atPath: path) } }
            return
        }
        switch outcome {
        case .ready(let binary, let spec):
            start(spec, provider: provider, binary: binary, session: session, turn: turn)
        case .failed(let ending, let status):
            finish(session, ending, status: status)
        }
    }

    private func start(_ spec: AIProcessRun.Spec, provider: AIProvider, binary: AIBinary, session: UUID, turn: UUID) {
        // The session may have closed, or the user pressed New Chat (and
        // maybe sent again), while the CLI was being found.
        guard conversations[session]?.running == true, conversations[session]?.provider == provider,
              conversations[session]?.turn == turn else {
            for path in spec.cleanup { try? FileManager.default.removeItem(atPath: path) }
            return
        }
        binaries[provider] = binary
        verified.insert(provider)
        status[provider] = .signedIn
        // The callbacks name their run: one that is no longer the session's
        // (New Chat + an immediate send) must not touch the new turn.
        let box = RunRef()
        let run = AIProcessRun(spec: spec, provider: provider, onEvent: { event in
            Task { @MainActor in AIPanelModel.shared.handle(event, session: session, run: box.run) }
        }, onExit: { ending in
            Task { @MainActor in AIPanelModel.shared.ended(ending, session: session, run: box.run) }
        })
        box.run = run
        runs.set(run, for: session)
        do {
            try run.start()
        } catch {
            runs.remove(session)
            finish(session, .failed(String(localized: "\(provider.label) couldn't start — Settings ▸ AI")), status: nil)
        }
    }

    /// Set once, before the run starts; read by its callbacks on main.
    private final class RunRef: @unchecked Sendable {
        weak var run: AIProcessRun?
    }

    private func handle(_ event: AIStreamEvent, session: UUID, run: AIProcessRun?) {
        guard let run, runs.isCurrent(run, for: session), conversations[session]?.running == true else { return }
        if case .delta(let text) = event {
            if deltas.add(text, for: session) {
                DispatchQueue.main.asyncAfter(deadline: .now() + AIDeltaBuffer.interval) {
                    AIPanelModel.shared.flushAllDeltas()
                }
            }
            return
        }
        flushDeltas(session)
        update(session) { c in
            guard let last = c.messages.indices.last, c.messages[last].role == .assistant else { return }
            switch event {
            case .delta(let text):
                c.messages[last].text += text
                if c.provider == .claude { c.claudeStarted = true }
            case .message(let text):
                if !c.messages[last].text.isEmpty { c.messages[last].text += "\n\n" }
                c.messages[last].text += text
                if c.provider == .claude { c.claudeStarted = true }
            case .session(let id):
                if c.provider == .gemini { c.geminiSession = id } else { c.codexThread = id }
            default:
                break
            }
        }
    }

    private func ended(_ ending: AIProcessRun.Ending, session: UUID, run: AIProcessRun?) {
        guard let run, runs.ended(run, for: session) else { return }
        flushDeltas(session)
        let provider = conversations[session]?.provider
        finish(session, ending, status: nil)
        if let provider, AIRunMessages.isNotSignedIn(ending, provider: provider) {
            status[provider] = .signedOut
            verified.remove(provider)
        }
    }

    private func appendStreamed(_ text: String, to session: UUID) {
        guard !text.isEmpty, conversations[session]?.running == true else { return }
        update(session) { c in
            guard let last = c.messages.indices.last, c.messages[last].role == .assistant else { return }
            c.messages[last].text += text
            if c.provider == .claude { c.claudeStarted = true }
        }
    }

    private func flushDeltas(_ session: UUID) {
        if let text = deltas.take(session) { appendStreamed(text, to: session) }
    }

    private func flushAllDeltas() {
        for (session, text) in deltas.takeAll() { appendStreamed(text, to: session) }
    }

    private func finish(_ session: UUID, _ ending: AIProcessRun.Ending, status newStatus: AIAccountStatus?) {
        if let newStatus, let provider = conversations[session]?.provider {
            status[provider] = newStatus
            if newStatus != .signedIn { verified.remove(provider) }
        }
        guard conversations[session] != nil else { return }
        update(session) { c in
            c.running = false
            guard let last = c.messages.indices.last, c.messages[last].role == .assistant else { return }
            switch ending {
            case .completed:
                if c.provider == .claude { c.claudeStarted = true }
            case .cancelled:
                c.messages[last].stopped = true
            case .aborted(let message), .failed(let message):
                c.messages[last].failure = message
                // A Claude session that never answered may not exist yet;
                // start the next turn on a fresh id rather than resume nothing.
                if c.provider == .claude, !c.claudeStarted { c.claudeSession = UUID() }
            }
        }
    }

    func stop(for session: UUID) {
        runs.run(for: session)?.cancel()
    }

    // MARK: Into the terminal

    /// Paste a suggested command into the session — never run it:
    /// `SessionTerminalHost.pasteFromAI` (one line typed without Return;
    /// several lines always reviewed, the last one left without its CR).
    func paste(_ code: String, into session: UUID) {
        guard !AIAnswerParser.pasteText(code).isEmpty, let host = AppModel.shared.terminalHost(ofSession: session) else {
            NSSound.beep(); return
        }
        host.pasteFromAI(code)
        AppModel.shared.focusActiveTerminal()
    }

    // MARK: Settings

    func refreshStatus() {
        guard !checking else { return }
        checking = true
        AIBinaryLocator.reset()
        Task.detached(priority: .userInitiated) {
            let env = ProcessInfo.processInfo.environment
            let planner = AIRunPlanner(root: AIRunPlanner.defaultRoot(), baseEnvironment: env,
                                       loginPath: AIBinaryLocator.loginPath(environment: env))
            var found: [AIProvider: AIBinary] = [:]
            var result: [AIProvider: AIAccountStatus] = [:]
            for provider in AIProvider.allCases {
                let binary = AIBinaryLocator.locate(provider, environment: env)
                if let binary { found[provider] = binary }
                result[provider] = planner.status(provider, binary: binary)
            }
            await MainActor.run {
                let model = AIPanelModel.shared
                model.binaries = found
                model.status = result
                model.verified = Set(result.filter { $0.value == .signedIn }.map(\.key))
                model.checking = false
            }
        }
    }

    func binaryPath(_ provider: AIProvider) -> String? { binaries[provider]?.path }

    /// Settings ▸ AI ▸ Sign In…: a new local tab running the vendor's own
    /// login command (the user clicked for exactly this).
    func signIn(_ provider: AIProvider) {
        guard let path = binaries[provider]?.path else { NSSound.beep(); return }
        AppModel.shared.newLocalTab()
        guard let session = AppModel.shared.selectedID else { return }
        let command = ([path] + provider.loginArguments).map(Self.shellQuoted).joined(separator: " ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppModel.shared.terminalHost(ofSession: session)?.sendCommand(command + "\n")
        }
        NSApp.activate()
        AppModel.shared.focusActiveTerminal()
    }

    static func shellQuoted(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func openInstallPage(_ provider: AIProvider) {
        if let url = URL(string: provider.installPage) { NSWorkspace.shared.open(url) }
    }
}
