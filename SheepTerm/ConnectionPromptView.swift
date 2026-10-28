import AppKit
import Combine
import SwiftUI
import Synchronization

/// What a connection prompt asks (4.2 (9)). Built on the worker queue from
/// the worker's own question, shown on the main actor by
/// `SessionTerminalHost.presentPrompt`. Everything in it already went
/// through `SSHWorker.printable` — the host is the user's, but a challenge's
/// text and a key type are the server's.
nonisolated struct ConnectionPrompt: Sendable {
    enum Step: Sendable {
        case username
        /// `account` = "user@host".
        case password(account: String)
        /// A keyboard-interactive question in the server's words; `secure`
        /// mirrors the server's echo flag.
        case challenge(text: String, secure: Bool)
        case hostKey(SSHWorker.HostKeyQuestion)
    }
    let step: Step
    /// Who asks: the tab's host, or the jump host when `viaJump`.
    let host: String
    /// The question is the bastion's login, not the tab's host's.
    let viaJump: Bool
    /// The tab's own host (for the jump-host tooltip).
    let tabHost: String
    /// The worker's prompt text, for the main-thread fallback panel.
    let fallbackText: String
    /// The server refused the last answer on this same connection and lets
    /// the user try again: the same page, field empty, a red line under it.
    var rejected = false

    var isSecure: Bool {
        switch step {
        case .password: return true
        case .challenge(_, let secure): return secure
        case .username, .hostKey: return false
        }
    }
}

/// How a question card was answered. `.cancel` covers Escape, Close and a
/// card taken down unanswered (tab closed, a newer question).
enum ConnectionPromptReply {
    case text(String)
    /// Host key: "Add and continue" (saved to known_hosts).
    case trust
    /// Host key: "Continue" (this session only, nothing saved).
    case trustOnce
    case cancel
}

extension ConnectionPrompt {
    /// Which node of the stage track the question belongs to.
    var stage: ConnectionStage {
        switch step {
        case .hostKey: return .hostKey
        case .username: return .user
        case .password, .challenge: return .password
        }
    }

    /// The text question as `ConnectionCardPlan` sees it (nil: host key).
    var planQuestion: ConnectionCardPlan.Question? {
        switch step {
        case .username: return .username
        case .password: return .password
        case .challenge(_, let secure): return .challenge(secure: secure)
        case .hostKey: return nil
        }
    }

    /// The text question's page (stage, red line, buttons).
    var plan: ConnectionCardPlan.Page? {
        planQuestion.map { ConnectionCardPlan.question($0, rejected: rejected) }
    }
}

/// The card's header: the session's title and "SSH address:port".
struct ConnectionCardHeader {
    let title: String
    let subtitle: String
    /// "name — address", the title of the window-centred form (narrow pane).
    let windowTitle: String
}

/// A web tab's untrusted certificate (`WebTabController`): the same question
/// as an SSH host key, on the same card.
struct WebCertificateQuestion {
    /// The server the certificate is for ("10.0.0.1:8443").
    let server: String
    /// Lowercase hex SHA-256 of the leaf (`WebTrust.hex`).
    let fingerprint: String
    /// A different certificate was trusted for this host before.
    let changed: Bool
    /// "Trust & Connect" is offered only for the saved host's own server —
    /// a third-party server on the page can be let in once, never pinned.
    let canTrust: Bool
}

/// What the card shows below the stage track.
enum ConnectionCardPage {
    /// "Connecting…" / "Authenticating…" with a spinner; Close cancels the
    /// connection.
    case progress(String)
    /// One of the worker's questions.
    case question(ConnectionPrompt)
    /// The connection failed: the reason in red, Close (and, for a pinned
    /// key that no longer matches, Open Known Hosts…; for anything Try
    /// Again can help, Try Again — the default). Buttons per `plan`.
    case failure(title: String, message: String, hostKeyProblem: Bool, plan: ConnectionCardPlan.Page)
    /// A web tab's certificate question (answers .trust / .trustOnce / .cancel).
    case certificate(WebCertificateQuestion)
}

/// What the user did on the card.
enum ConnectionCardAction {
    case answer(ConnectionPromptReply)
    /// Close on a progress or failure page (Escape too).
    case close
    case openKnownHosts
    /// Failure page: connect to the same host again, from the start.
    case tryAgain
}

/// What the card shows, observed by `ConnectionCardContent`.
@MainActor
final class ConnectionCardModel: ObservableObject {
    @Published var header: ConnectionCardHeader
    @Published var stage: ConnectionStage = .connect
    @Published var page: ConnectionCardPage = .progress(String(localized: "Connecting…"))
    /// Bumped by every `show`: the page's own state (what was typed) is
    /// discarded with the page.
    @Published var pageID = 0
    /// Bumped to put the caret in the page's field (`PopupTextEntry`).
    @Published var focusRequest = 0
    /// The page being shown replaced one that had the keyboard: its field
    /// takes the caret on appear.
    @Published var focusOnAppear = false
    /// Hosted in the window-centred panel: room for its title at the top.
    @Published var inPanel = false
    /// Every stage the same size (the user's rule): the tallest page's
    /// height, measured once. nil while measuring.
    var fixedHeight: CGFloat?

    var onAction: ((ConnectionCardAction) -> Void)?
    /// The question page's state: busy from the moment an answer is
    /// submitted until the next page replaces it (`show` makes a new one).
    @Published var entry = ConnectionCardPlan.Entry(question: nil)
    /// Cancel while `entry.busy`: the answer is with the worker already, so
    /// this cancels the connection (set by `show` for question pages).
    var onBusyCancel: (() -> Void)?
    var onFocus: (() -> Void)?
    var onTap: (() -> Void)?

    init(header: ConnectionCardHeader) {
        self.header = header
    }

    /// At most once per page.
    func send(_ action: ConnectionCardAction) {
        guard let onAction else { return }
        self.onAction = nil
        onAction(action)
    }

    /// The stage track: SSH's five nodes, or a web tab's three (`webTrack`).
    @Published var webTrack = false
    /// A Files tab's track (`FilesPlan.cardNodes`): the SSH nodes with
    /// "Files" last, fewer for FTP / TFTP. nil = not a Files tab.
    @Published var filesTrack: [FilesPlan.CardNode]?

    func escape() {
        switch page {
        case .question:
            switch entry.cancel() {
            case .cancelQuestion: send(.answer(.cancel))
            case .cancelConnection: onBusyCancel?()
            }
        case .certificate: send(.answer(.cancel))
        default: send(.close)
        }
    }

    var hasField: Bool {
        if entry.busy { return false }
        if case .question(let prompt) = page, case .hostKey = prompt.step { return false }
        if case .question = page { return true }
        return false
    }
}

/// The card a session shows while it connects (4.2 (9)) — the EXISTING
/// popups put in the tab (the user's word: "เอาของ popup เดิมมาเลย"): the
/// same glass (`popupChrome`), width, title/text layout, text entry
/// (`PopupTextEntry`), fingerprint block (`FingerprintBlock`) and buttons as
/// AuthPromptView / HostKeyPromptView. Since 6.0 (10) no icon: the stage
/// track (one segmented capsule) is the top of the card. Every stage has
/// the same frame AND the same four slots at the same heights — track,
/// two title lines, the band (field + its red line), buttons — so nothing
/// moves between steps (the user's layout, 2026-10-27).
///
/// This AppKit view hosts the SwiftUI content and is the responder chain's
/// stop: it handles Return/Escape on pages without a field and swallows every
/// other key, so nothing typed here can reach the terminal view behind it
/// (its next responder) and the device. `SessionTerminalHost` places it —
/// centred over the dimmed terminal, or in a window-centred panel when the
/// pane is too small. See ARCHITECTURE.md §15.
final class ConnectionCardView: NSView {
    let model: ConnectionCardModel
    private let hosting: NSHostingView<ConnectionCardContent>

    /// The card's one size, every stage: measured from the host-key page
    /// (the tallest) once.
    static let cardSize: NSSize = {
        let sample = ConnectionCardModel(header: ConnectionCardHeader(title: "sample", subtitle: "SSH 255.255.255.255:65535",
                                                                      windowTitle: ""))
        let question = SSHWorker.HostKeyQuestion(host: "255.255.255.255", port: 65535, keyType: "ecdsa-sha2-nistp521",
                                                 fingerprint: "SHA256:" + String(repeating: "W", count: 43))
        sample.stage = .hostKey
        sample.page = .question(ConnectionPrompt(step: .hostKey(question), host: "255.255.255.255", viaJump: true,
                                                 tabHost: "255.255.255.255", fallbackText: ""))
        let probe = NSHostingView(rootView: ConnectionCardContent(model: sample))
        let size = probe.fittingSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }()

    /// The panel's title ("name — address") takes this much at the top.
    static let panelTitleBand: CGFloat = 14
    /// The card's width, every stage (content column 424 + 2 × 28): an
    /// SSH fingerprint fits on one line with its key type beside it.
    static let cardWidth: CGFloat = 480

    var header: ConnectionCardHeader { model.header }
    var stage: ConnectionStage { model.stage }
    var page: ConnectionCardPage { model.page }

    var onFocus: (() -> Void)? {
        get { model.onFocus }
        set { model.onFocus = newValue }
    }

    /// In a pane (true) or inside the panel (false — the panel's title sits
    /// in the top band, the content moves down under it).
    var drawsChrome = true {
        didSet { model.inPanel = !drawsChrome }
    }

    init(header: ConnectionCardHeader) {
        model = ConnectionCardModel(header: header)
        model.fixedHeight = Self.cardSize.height
        hosting = NSHostingView(rootView: ConnectionCardContent(model: model))
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        model.onTap = { [weak self] in self?.takeKeyboard() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `page` at `stage`; `action` replaces the previous page's
    /// handler. The keyboard stays with the card across pages.
    func show(stage: ConnectionStage, page: ConnectionCardPage, busyCancel: (() -> Void)? = nil,
              action: @escaping (ConnectionCardAction) -> Void) {
        let hadKeyboard = hasKeyboard
        if case .question(let prompt) = page {
            model.entry = ConnectionCardPlan.Entry(question: prompt.planQuestion)
        } else {
            model.entry = ConnectionCardPlan.Entry(question: nil)
        }
        model.onBusyCancel = busyCancel
        model.focusOnAppear = hadKeyboard
        model.stage = stage
        model.page = page
        model.pageID &+= 1
        model.onAction = action
        if hadKeyboard {
            // After SwiftUI has installed the new page.
            DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
        }
    }

    // MARK: - keyboard

    /// Whether the keyboard is in this card (a field's editor, a control, or
    /// the card itself).
    var hasKeyboard: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        if let editor = responder as? NSTextView, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        if let view = responder as? NSView { return view.isDescendant(of: self) }
        return false
    }

    /// Gives the card the keyboard: the page's field, or the card itself (so
    /// Return and Escape answer the page). False without a window.
    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        if window is ConnectionCardPanel, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        if model.hasField {
            if !(hasKeyboard && window.firstResponder is NSTextView) { model.focusRequest &+= 1 }
            return true
        }
        if window.firstResponder === self { return true }
        return window.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { model.onFocus?() }
        return ok
    }

    /// The card has the keyboard on a page without a field. Escape closes;
    /// Return answers the page's SAFE choice (Cancel on the host key — trust
    /// takes a deliberate click — Close on a failure, nothing while
    /// connecting); nothing else does anything, and nothing may fall through
    /// to `super`, whose next responder is the terminal view.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            model.escape()
        case 36, 76:
            switch model.page {
            case .progress: NSSound.beep()
            case .failure(_, _, _, let plan): model.send(plan.returnKey == .tryAgain ? .tryAgain : .close)
            case .question where model.entry.busy: NSSound.beep()
            case .question, .certificate: model.send(.answer(.cancel))
            }
        default:
            NSSound.beep()
        }
    }

    /// Escape from inside a field arrives here up the responder chain.
    override func cancelOperation(_ sender: Any?) { model.escape() }

    /// An action nobody in the card handles stops here instead of walking on
    /// into the terminal view (`nextResponder`).
    override func doCommand(by selector: Selector) {}

    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        responds(to: action) ? super.tryToPerform(action, with: object) : false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// The SwiftUI side of the card: four slots at fixed heights, top to
/// bottom — the stage track, two title lines, the band (a field and its red
/// line, a fingerprint, a spinner or a message) and the button row — the
/// same on every page (the user's layout, 6.0 (10)).
struct ConnectionCardContent: View {
    @ObservedObject var model: ConnectionCardModel

    var body: some View {
        VStack(spacing: Self.slotGap) {
            if model.webTrack {
                StageTrack(nodes: StageTrack.webNodes, current: model.stage == .connect ? 0 : 1, failed: isFailure)
            } else if let nodes = model.filesTrack {
                StageTrack(nodes: nodes.map(StageTrack.node(for:)),
                           current: FilesPlan.cardIndex(model.stage, in: nodes), failed: isFailure)
            } else {
                StageTrack(current: model.stage, failed: isFailure)
            }
            titles
                .frame(height: Self.titlesHeight, alignment: .top)
            // Not `.id(pageID)`-swapped: replacing the whole page re-created
            // the glass and flickered between steps (the user, 2026-10-09).
            // Pages switch in place, without animation; the entry page
            // resets its own text on `pageID`.
            pageBody
                .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .padding(.top, model.inPanel ? ConnectionCardView.panelTitleBand : 0)
        .frame(width: ConnectionCardView.cardWidth)
        // `popupChrome` adds 10 pt each side around this frame.
        .frame(height: model.fixedHeight.map { $0 - 20 + (model.inPanel ? ConnectionCardView.panelTitleBand : 0) },
               alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.onTap?() }
        .onExitCommand { model.escape() }
        .popupChrome()
    }

    /// The space between two slots.
    static let slotGap: CGFloat = 12

    private var isFailure: Bool {
        if case .failure = model.page { return true }
        return false
    }

    /// Two lines on every page (15 pt semibold title, 12 pt secondary line,
    /// centred): the host's name — "user@name" on the password page — and
    /// "SSH address:port" under it; the bastion's while the question is the
    /// jump host's. What used to be a third line lives elsewhere: a changed
    /// key or certificate is the red title itself, "compare the fingerprint"
    /// is the fingerprint's tooltip, a challenge's words are its field's
    /// placeholder, a failure's message and "Connecting…" are the band's.
    @ViewBuilder private var titles: some View {
        VStack(spacing: 3) {
            switch model.page {
            case .progress:
                title(model.header.title)
                secondary(model.header.subtitle)
            case .question(let prompt):
                let name = prompt.viaJump ? prompt.host : model.header.title
                let endpoint = prompt.viaJump ? String(localized: "jump host for \(prompt.tabHost)") : model.header.subtitle
                switch prompt.step {
                case .hostKey(let question):
                    let host = prompt.viaJump ? question.target : name
                    switch question.conflict {
                    case .changed?:
                        title(String(localized: "Host key CHANGED"), red: true)
                        secondary("\(host) · \(endpoint)")
                    case .typeChanged?:
                        title(String(localized: "Host key TYPE changed"), red: true)
                        secondary("\(host) · \(endpoint)")
                    case nil:
                        title(host)
                        secondary(endpoint)
                    }
                case .password(let account):
                    title(ConnectionCardPlan.passwordTitle(account: account, name: name))
                    secondary(endpoint)
                case .challenge(let text, _):
                    // The server's question is the second line — cut at its
                    // START, so the question itself (its end) stays in view;
                    // the whole of it on hover (review 6.0 (11): as the
                    // field's placeholder a Duo-style list of options was lost).
                    title(name)
                    if let question = Self.challengeQuestion(text) {
                        Text(question).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                            .help(question)
                    } else {
                        secondary(endpoint)
                    }
                case .username:
                    title(name)
                    secondary(endpoint)
                }
            case .failure(let heading, _, _, _):
                // A failure's title is always the old card's red (card J).
                title(heading, red: true)
                secondary(model.header.subtitle)
            case .certificate(let question):
                if question.changed {
                    title(String(localized: "Certificate CHANGED"), red: true)
                    secondary("\(model.header.title) · \(question.server)")
                } else {
                    title(model.header.title)
                    secondary(question.server)
                }
            }
        }
    }

    /// A challenge's words as one line (the worker already turned its line
    /// breaks into blanks — `SSHWorker.printable`), runs of blanks folded;
    /// nil when the server sent none.
    static func challengeQuestion(_ text: String) -> String? {
        let folded = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    /// The title slot: one title line and one 12 pt line.
    static let titlesHeight: CGFloat = {
        let probe = NSHostingView(rootView: VStack(spacing: 3) {
            Text(verbatim: "Ag").font(.system(size: 15, weight: .semibold))
            Text(verbatim: "Ag").font(.system(size: 12))
        })
        return ceil(probe.fittingSize.height)
    }()

    private func title(_ text: String, red: Bool = false) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(red ? Color(nsColor: SheepAlert.destructiveRed) : Color.primary)
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }

    @ViewBuilder private var pageBody: some View {
        switch model.page {
        case .progress(let text):
            CardPage(content: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: CardPage<EmptyView, EmptyView>.fieldHeight)
            }, buttons: {
                CardButton(String(localized: "Cancel"), role: .neutral, help: String(localized: "Cancel the connection (Esc)")) { model.escape() }
            })
        case .question(let prompt):
            if case .hostKey(let question) = prompt.step {
                if question.conflict != nil {
                    ChangedHostKeyPage(model: model, question: question)
                } else {
                    HostKeyPage(model: model, question: question)
                }
            } else {
                EntryPage(model: model, prompt: prompt)
            }
        case .certificate(let question):
            CertificatePage(model: model, question: question)
        case .failure(_, let message, _, let plan):
            // Apple's order: the dismiss left of the action; the default
            // (Try Again, Return) rightmost.
            CardPage(content: {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .frame(height: CardPage<EmptyView, EmptyView>.bandHeight)
                    .help(message)
            }, buttons: {
                ForEach(plan.buttons.indices, id: \.self) { index in
                    switch plan.buttons[index] {
                    case .openKnownHosts:
                        CardButton(String(localized: "Open Known Hosts…"), role: .accent, help: String(localized: "Review the saved key")) { model.send(.openKnownHosts) }
                    case .tryAgain:
                        CardButton(String(localized: "Try Again"), role: .green, help: String(localized: "Return")) { model.send(.tryAgain) }
                    default:
                        CardButton(String(localized: "Close"), role: .neutral, help: String(localized: "Close this message")) { model.send(.close) }
                    }
                }
            })
        }
    }
}

/// The last two slots of a card page: the band (one fixed height — the text
/// entry with its always-laid-out red line, the tallest — content at its
/// top) and the button row (equal-width capsules across the column; a lone
/// button is half the column, centred).
struct CardPage<Content: View, Buttons: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    /// The text entry's own height (field + red line): the band.
    static var bandHeight: CGFloat { CardBand.size.band }
    /// The field box alone: a fingerprint or a spinner is drawn this tall,
    /// on the field's line.
    static var fieldHeight: CGFloat { CardBand.size.field }

    var body: some View {
        VStack(spacing: ConnectionCardContent.slotGap) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: Self.bandHeight, alignment: .top)
            ButtonRow { buttons() }
                .frame(height: 30)
        }
    }
}

/// Measured once from the real `PopupTextEntry`, so the band can never
/// drift from the field it holds.
@MainActor enum CardBand {
    static let size: (band: CGFloat, field: CGFloat) = {
        let entry = NSHostingView(rootView: PopupTextEntry(placeholder: "Ag", secure: true, text: .constant(""),
                                                           focusTrigger: 0, onSubmit: {}))
        let line = NSHostingView(rootView: Text(verbatim: "Ag").font(.system(size: 10)))
        let band = ceil(entry.fittingSize.height)
        // PopupTextEntry: the box, 8 pt, then the 10 pt status line.
        return (band, band - 8 - ceil(line.fittingSize.height))
    }()
}

/// The buttons across the content column, equal widths; one button alone
/// is half the column, centred.
struct ButtonRow: Layout {
    static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(max(subviews.count, 2))
        let width = (bounds.width - Self.spacing * (count - 1)) / count
        let total = width * CGFloat(subviews.count) + Self.spacing * CGFloat(subviews.count - 1)
        var x = bounds.midX - total / 2
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + Self.spacing
        }
    }
}

/// One capsule button of the card's row — the popup's TrustButtonStyle in
/// its fills (neutral / accent / green / caution), as wide as `ButtonRow`
/// gives it.
struct CardButton: View {
    /// `danger`: the old card's red (the dangerous-command card's Send).
    enum Role { case neutral, accent, green, caution, danger }
    let title: String
    let role: Role
    let help: String
    /// Waiting for the server's answer: a small spinner in place of the
    /// label, same size and colour, button off.
    let busy: Bool
    let action: () -> Void

    init(_ title: String, role: Role, help: String, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.help = help; self.busy = busy; self.action = action
    }

    var body: some View {
        Button(action: action) {
            // The label keeps its place (invisible) so the capsule is the
            // same size; the spinner sits over it.
            // 0.7: three buttons in a long language (fr / ru) still read whole.
            Text(title).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.horizontal, 8)
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy { ProgressView().controlSize(.small).environment(\.colorScheme, .dark) }
                }
        }
            .buttonStyle(style)
            .focusable(false)
            .help(help)
    }

    private var style: TrustButtonStyle {
        switch role {
        case .neutral: return TrustButtonStyle(fill: Color.primary.opacity(0.12), foreground: .primary)
        case .accent: return TrustButtonStyle(fill: Theme.accent, foreground: .white)
        case .green: return TrustButtonStyle()
        case .caution: return TrustButtonStyle(fill: Color(nsColor: SheepAlert.cautionYellow), foreground: .white)
        case .danger: return TrustButtonStyle(fill: Color(nsColor: SheepAlert.destructiveRed), foreground: .white)
        }
    }
}

/// Username / password / challenge: AuthPromptView's field and buttons. No
/// `.keyboardShortcut` here — in a window with several panes a Return
/// shortcut would answer this card from another pane's terminal; Return is
/// the field's `onSubmit`, Escape the card's.
private struct EntryPage: View {
    @ObservedObject var model: ConnectionCardModel
    let prompt: ConnectionPrompt
    @State private var text = ""

    private func submit() {
        // `ConnectionCardPlan.Entry` decides: empty is not an answer the
        // worker can use (Escape cancels; Return on empty says no), and a
        // second submit while waiting for the server answers nothing.
        switch model.entry.submit(text) {
        case .send(let value):
            text = ""
            model.send(.answer(.text(value)))
            // The field is off now: the keyboard moves to the card, so
            // Escape still reaches it.
            DispatchQueue.main.async { model.onTap?() }
        case .refuseEmpty:
            NSSound.beep()
        case .ignored:
            break
        }
    }

    var body: some View {
        CardPage(content: {
            // The content column's width, like the buttons under it (6.0 (10)).
            PopupTextEntry(placeholder: placeholder, secure: prompt.isSecure, text: $text,
                           focusTrigger: model.focusRequest, focusOnAppear: model.focusOnAppear,
                           error: localizedNote(prompt.plan?.note),
                           onSubmit: submit) { focused in
                if focused { model.onFocus?() }
            }
            .disabled(model.entry.busy)
            .id(model.pageID)
        }, buttons: {
            CardButton(String(localized: "Cancel"), role: .neutral, help: String(localized: "Cancel the connection (Esc)")) { model.escape() }
            CardButton(submitTitle, role: .green, help: String(localized: "Return"), busy: model.entry.busy, action: submit)
        })
        .onChange(of: model.pageID) { _, _ in text = "" }
#if DEBUG
        // Screenshot runs only (compiled out of Release): SHEEPTERM_DEBUG_CARD_TYPE=<text>
        // types it into the FIRST password page and presses Connect through the real path.
        .onAppear {
            guard case .password = prompt.step, let value = Self.debugType.withLock({ v -> String? in defer { v = nil }; return v })
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { text = value; submit() }
        }
#endif
    }
#if DEBUG
    private static let debugType = Mutex<String?>(ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_CARD_TYPE"])
#endif

    private var submitTitle: String {
        if case .submit(let title)? = prompt.plan?.returnKey {
            switch title {
            case "Connect": return String(localized: "Connect")
            case "Continue": return String(localized: "Continue")
            default: return title
            }
        }
        return prompt.isSecure ? String(localized: "Connect") : String(localized: "Continue")
    }

    /// The shared plan's red line, from the string catalog (see
    /// `ConnectionStage.localizedLabel`).
    private func localizedNote(_ note: String?) -> String? {
        switch note {
        case "Wrong password": return String(localized: "Wrong password")
        case "Not accepted — try again": return String(localized: "Not accepted — try again")
        default: return note
        }
    }

    private var placeholder: String {
        switch prompt.step {
        case .username: return String(localized: "Username")
        case .password: return String(localized: "Password")
        case .challenge(_, let secure):
            // The server's words are the second title line, not this.
            return secure ? String(localized: "Answer (hidden)") : String(localized: "Answer")
        case .hostKey: return ""
        }
    }
}

/// HostKeyPromptView's block and buttons, plus "Connect Once" (trusted for
/// this session, nothing written).
private struct HostKeyPage: View {
    @ObservedObject var model: ConnectionCardModel
    let question: SSHWorker.HostKeyQuestion

    var body: some View {
        let base64 = question.fingerprint.hasPrefix("SHA256:") ? String(question.fingerprint.dropFirst(7)) : question.fingerprint
        CardPage(content: {
            CardFingerprint(label: "\(HostKeyPromptView.keyTypeLabel(question.keyType)) · SHA256", lines: [base64],
                            help: String(localized: "First connection — compare the fingerprint before you trust it."))
        }, buttons: {
            // Apple's order (the user's call, 2026-10-10): the alternative
            // (Connect Once) at the far left, then Cancel immediately left of
            // the main action (Trust & Connect). Trust is green and takes a
            // deliberate click — Return and Escape answer Cancel (the card's
            // keyDown) and no button takes the keyboard's focus.
            CardButton(String(localized: "Connect Once"), role: .caution,
                       help: String(localized: "Connect this time only — the key is not saved and the next connection asks again")) { model.send(.answer(.trustOnce)) }
            CardButton(String(localized: "Cancel"), role: .neutral,
                       help: String(localized: "Don't trust this key — the connection is cancelled and nothing is saved (Return / Esc)")) { model.send(.answer(.cancel)) }
            CardButton(String(localized: "Trust & Connect"), role: .green, help: String(localized: "Save this key to known_hosts and connect")) { model.send(.answer(.trust)) }
        })
    }
}

/// A host key that does not match the pin in the user's known_hosts (an HA
/// pair's other box, a reinstalled device — or a man-in-the-middle). Cancel
/// is the safe answer and what Return / Esc give (the card's keyDown); "Trust
/// This Key Too" takes a click AND a second, explicit confirmation, and adds
/// the key BESIDE the old one (both boxes of an HA pair then connect quietly).
private struct ChangedHostKeyPage: View {
    @ObservedObject var model: ConnectionCardModel
    let question: SSHWorker.HostKeyQuestion
    @State private var confirming = false

    var body: some View {
        let base64 = question.fingerprint.hasPrefix("SHA256:") ? String(question.fingerprint.dropFirst(7)) : question.fingerprint
        CardPage(content: {
            if confirming {
                Text("Only if this host is an HA pair or you know its key was replaced. Both keys will be trusted for \(question.target).")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: SheepAlert.destructiveRed))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    // The host's name is the sentence's end: shrink, never cut it.
                    .minimumScaleFactor(0.75)
                    .frame(maxHeight: .infinity)
            } else {
                CardFingerprint(label: "\(HostKeyPromptView.keyTypeLabel(question.keyType)) · SHA256", lines: [base64], danger: true,
                                help: question.conflict == .typeChanged
                                    ? String(localized: "The host key TYPE has changed since you trusted it.")
                                    : String(localized: "The host key has CHANGED since you trusted it."))
            }
        }, buttons: {
            if confirming {
                CardButton(String(localized: "Back"), role: .neutral,
                           help: String(localized: "Back to the key")) { confirming = false }
                CardButton(String(localized: "Trust Both Keys"), role: .caution,
                           help: String(localized: "Add this key to known_hosts beside the one already pinned, and connect")) { model.send(.answer(.trust)) }
            } else {
                CardButton(String(localized: "Trust This Key Too…"), role: .caution,
                           help: String(localized: "For an HA pair or a replaced key: keep the pinned key and add this one")) { confirming = true }
                CardButton(String(localized: "Cancel"), role: .neutral,
                           help: String(localized: "Don't trust this key — the connection is cancelled and nothing is saved (Return / Esc)")) { model.send(.answer(.cancel)) }
            }
        })
    }
}

/// A web tab's certificate: HostKeyPage's layout and buttons — the
/// fingerprint as two lines of colon pairs (a SHA-256 in hex is too long for
/// one), Connect Once / Cancel / Trust & Connect. Return and Escape answer
/// Cancel (the card's keyDown), never Trust.
private struct CertificatePage: View {
    @ObservedObject var model: ConnectionCardModel
    let question: WebCertificateQuestion

    var body: some View {
        let lines = WebTrust.displayLines(question.fingerprint)
        CardPage(content: {
            CardFingerprint(label: "SHA-256", lines: [lines.0, lines.1], danger: question.changed,
                            help: question.changed ? String(localized: "The certificate has CHANGED since you trusted it.")
                                                   : String(localized: "Untrusted certificate — compare the fingerprint before you trust it."))
        }, buttons: {
            CardButton(String(localized: "Connect Once"), role: .caution,
                       help: String(localized: "Open this time only — nothing is saved and the next visit asks again")) { model.send(.answer(.trustOnce)) }
            CardButton(String(localized: "Cancel"), role: .neutral,
                       help: String(localized: "Don't trust this certificate — nothing is loaded or saved (Return / Esc)")) { model.send(.answer(.cancel)) }
            if question.canTrust {
                CardButton(String(localized: "Trust & Connect"), role: .green,
                           help: question.changed ? String(localized: "Replace the trusted certificate with this one and open the page")
                                                  : String(localized: "Remember this certificate for this host and open the page")) { model.send(.answer(.trust)) }
            }
        })
    }
}

/// A fingerprint on the field's line, the field's height: its kind in a
/// small chip, then the value in monospace (one line for SSH, two for a
/// certificate's hex). Red edge for a key or certificate that changed; the
/// advice ("compare … before you trust it") is the tooltip.
private struct CardFingerprint: View {
    let label: String
    let lines: [String]
    var danger = false
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines.indices, id: \.self) { Text(lines[$0]) }
            }
            .font(.system(size: lines.count > 1 ? 10.5 : 12, weight: .medium, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.75)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: CardPage<EmptyView, EmptyView>.fieldHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(danger ? Color(nsColor: SheepAlert.destructiveRed).opacity(0.7) : Color.primary.opacity(0.14), lineWidth: 1))
        .help(help)
    }
}

/// The stage track: one capsule split into a segment per stage — Connect ·
/// Host key · User · Password · Terminal — each a 12 pt glyph, the current
/// one also naming itself. Passed segments in the icon's frost at 45 %, the
/// current one full frost with a white glow, future glyphs grey; a failure
/// paints the current segment red (card J, 6.0 (10)).
struct StageTrack: View {
    struct Node {
        let label: String
        let symbol: String
    }
    /// A web tab's track: Connect · Certificate · Page.
    static let webNodes = [Node(label: String(localized: "Connect"), symbol: ConnectionStage.connect.symbol),
                           Node(label: String(localized: "Certificate"), symbol: "key.fill"),
                           Node(label: String(localized: "Page"), symbol: "globe")]

    /// A Files tab's node: the SSH stage's own, "Files" for the last.
    static func node(for files: FilesPlan.CardNode) -> Node {
        let stage: ConnectionStage
        switch files {
        case .connect: stage = .connect
        case .hostKey: stage = .hostKey
        case .user: stage = .user
        case .password: stage = .password
        case .files: return Node(label: String(localized: "Files"), symbol: "folder.fill")
        }
        return Node(label: stage.localizedLabel, symbol: stage.symbol)
    }

    let nodes: [Node]
    let current: Int
    let failed: Bool
    /// The muted blue of the app icon's ring.
    private static let frost = Color(red: 0.36, green: 0.53, blue: 0.69)

    init(current: ConnectionStage, failed: Bool) {
        nodes = ConnectionStage.allCases.map { Node(label: $0.localizedLabel, symbol: $0.symbol) }
        self.current = current.rawValue
        self.failed = failed
    }

    init(nodes: [Node], current: Int, failed: Bool) {
        self.nodes = nodes
        self.current = current
        self.failed = failed
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(nodes.indices, id: \.self) { segment($0) }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .frame(maxWidth: .infinity)
    }

    private func segment(_ index: Int) -> some View {
        let stage = nodes[index]
        let isCurrent = index == current
        let fill: Color = isCurrent ? (failed ? Color(nsColor: SheepAlert.destructiveRed) : Self.frost)
            : index < current ? Self.frost.opacity(0.45) : .clear
        let glow: Color = isCurrent ? (failed ? Color(nsColor: SheepAlert.destructiveRed).opacity(0.45) : Color.white.opacity(0.25)) : .clear
        return HStack(spacing: 6) {
            Image(systemName: stage.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(index <= current ? Color.white : Theme.dimText)
            if isCurrent {
                Text(stage.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(fill).shadow(color: glow, radius: 4))
        .help(stage.label)
    }
}

/// The window-centred form of the card, for a pane too small to hold it
/// (the font never shrinks). A child window of the main window, NOT modal:
/// the bridge waits, the app runs.
final class ConnectionCardPanel: NSPanel {
    var onClose: (() -> Void)?

    init(title: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ConnectionCardView.cardSize.width, height: ConnectionCardView.cardSize.height),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.title = title
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        for type in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }

    /// While the card has the keyboard here, a click in the window it floats
    /// over hands the keyboard back FIRST, so that click lands (a tab chip,
    /// a button): it took two clicks — the first only made the window key
    /// (the user, 6.0 (2)). Every tab that uses the panel (SSH, Telnet,
    /// serial, Files) gets it here.
    private var clickMonitor: Any?

    override func becomeKey() {
        super.becomeKey()
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, let target = event.window, target !== self, target === self.parent, !target.isKeyWindow {
                target.makeKey()
            }
            return event
        }
    }

    override func resignKey() {
        super.resignKey()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// The close button is the card's Close (Escape), never a bare close.
    override func performClose(_ sender: Any?) { onClose?() }
}

/// Fills the session's terminal view while a card is up. In the pane it is
/// the veil (the terminal keeps rendering underneath) and the card sits
/// centred on it; when the card lives in a panel it is invisible and lets
/// every click through. Reports size and window changes so the host can
/// move the card between the two.
final class ConnectionOverlayView: NSView {
    var onGeometryChange: (() -> Void)?
    /// A click on the veil, for a card that is not a `ConnectionCardView`
    /// (the dangerous-command question).
    var onVeilClick: (() -> Void)?
    /// Posted when a veil goes up, comes down or moves to another view: the
    /// pane tree veils the margin round the terminal to match (`PaneVeil`).
    static let veilDidChange = Notification.Name("SheepTerm.ConnectionOverlayView.veilDidChange")
    static let veilColor = NSColor.black.withAlphaComponent(0.45)

    var veiled = true {
        didSet {
            guard veiled != oldValue else { return }
            layer?.backgroundColor = veiled ? Self.veilColor.cgColor : nil
            window?.invalidateCursorRects(for: self)
            NotificationCenter.default.post(name: Self.veilDidChange, object: self)
        }
    }
    weak var card: ConnectionCardView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.veilColor.cgColor
        autoresizingMask = [.width, .height]
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.post(name: Self.veilDidChange, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard veiled else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click on the veil goes to the card, never to the terminal under it.
    override func mouseDown(with event: NSEvent) {
        card?.takeKeyboard()
        onVeilClick?()
    }

    override func resetCursorRects() {
        if veiled { addCursorRect(bounds, cursor: .arrow) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onGeometryChange?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onGeometryChange?()
    }
}

/// The stage track's labels, from the string catalog: `ConnectionCardPlan.swift`
/// is shared with the Windows build (root `Package.swift`) and keeps its
/// English `label` for the harness, so the localized spelling lives here.
extension ConnectionStage {
    var localizedLabel: String {
        switch self {
        case .connect: return String(localized: "Connect")
        case .hostKey: return String(localized: "Host key")
        case .user: return String(localized: "User")
        case .password: return String(localized: "Password")
        case .terminal: return String(localized: "Terminal")
        }
    }
}


#if DEBUG
/// Screenshot runs only (compiled out of Release): SHEEPTERM_DEBUG_CARD_GALLERY=<png>
/// opens one window of sample cards (sample data) over a dimmed backdrop and
/// writes it to that file.
enum ConnectionCardGallery {
    static func show(writingTo path: String) {
        let header = ConnectionCardHeader(title: "core-sw1", subtitle: "SSH 192.0.2.10:22", windowTitle: "")
        func prompt(_ step: ConnectionPrompt.Step, rejected: Bool = false, jump: Bool = false) -> ConnectionPrompt {
            var p = ConnectionPrompt(step: step, host: jump ? "bastion" : "core-sw1", viaJump: jump, tabHost: "core-sw1", fallbackText: "")
            p.rejected = rejected
            return p
        }
        let key = SSHWorker.HostKeyQuestion(host: "192.0.2.10", port: 22, keyType: "ssh-ed25519",
                                            fingerprint: "SHA256:Xq3v9Lk2bWmT7pR1nA8sYc4eHd0uJf6gZo5iKw2ElQ")
        var changed = SSHWorker.HostKeyQuestion(host: "192.0.2.10", port: 22, keyType: "ssh-ed25519",
                                                fingerprint: "SHA256:p0Rt7mQ2xVb9Lc4nE1sKd8yHa3uJf6gWo5iZw2TlNe")
        changed.conflict = .changed
        let samples: [(ConnectionStage, ConnectionCardPage, Bool)] = [
            (.connect, .progress(String(localized: "Connecting…")), false),
            (.hostKey, .question(prompt(.hostKey(key))), false),
            (.hostKey, .question(prompt(.hostKey(changed))), false),
            (.user, .question(prompt(.username)), false),
            (.password, .question(prompt(.password(account: "admin@core-sw1"))), false),
            (.password, .question(prompt(.password(account: "admin@core-sw1"), rejected: true)), false),
            (.password, .question(prompt(.challenge(text: "Enter a passcode or select one of the following options: 1. Duo Push to XXX-XXX-1234 2. Phone call to XXX-XXX-1234 Passcode or option (1-2):", secure: false))), false),
            (.password, .question(prompt(.password(account: "admin@bastion"), jump: true)), false),
            (.password, .failure(title: String(localized: "Authentication failed"), message: "The server refused the password for admin.",
                                 hostKeyProblem: false, plan: ConnectionCardPlan.failure(at: .password, offersKnownHosts: false, offersTryAgain: true)), false),
            (.hostKey, .certificate(WebCertificateQuestion(server: "https://192.0.2.1", fingerprint: String(repeating: "4f9a12c73e88b10d", count: 4),
                                                           changed: false, canTrust: true)), true),
        ]
        let size = ConnectionCardView.cardSize
        // Then the dangerous-command card (card J, 6.0 (11)): SSH, serial, telnet.
        let guards = [("core-sw1", "reload"), ("Console · usbserial-A10K", "write erase"), ("fw-lab", "show interfaces status ; reload ; show interfaces brief detail")]
        let columns = 2, gap: CGFloat = 16
        let rows = (samples.count + guards.count + columns - 1) / columns
        let frame = NSRect(x: 0, y: 0, width: CGFloat(columns) * (size.width + gap) + gap,
                           height: CGFloat(rows) * (size.height + gap) + gap)
        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.termBackgroundNS.blended(withFraction: 0.45, of: .black)?.cgColor
        for (index, sample) in samples.enumerated() {
            let model = ConnectionCardModel(header: sample.2 ? ConnectionCardHeader(title: "fw.lab.example", subtitle: "https://192.0.2.1", windowTitle: "") : header)
            model.fixedHeight = size.height
            model.stage = sample.0
            model.page = sample.1
            model.webTrack = sample.2
            if case .question(let p) = sample.1 { model.entry = ConnectionCardPlan.Entry(question: p.planQuestion) }
            let host = NSHostingView(rootView: ConnectionCardContent(model: model))
            let col = index % columns, row = index / columns
            host.frame = NSRect(x: gap + CGFloat(col) * (size.width + gap),
                                y: frame.height - CGFloat(row + 1) * (size.height + gap),
                                width: size.width, height: size.height)
            root.addSubview(host)
        }
        for (offset, sample) in guards.enumerated() {
            let index = samples.count + offset
            let host = NSHostingView(rootView: CommandGuardCardContent(title: sample.0, command: sample.1, answer: { _ in }, tap: {}))
            let col = index % columns, row = index / columns
            host.frame = NSRect(x: gap + CGFloat(col) * (size.width + gap),
                                y: frame.height - CGFloat(row + 1) * (size.height + gap),
                                width: size.width, height: size.height)
            root.addSubview(host)
        }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: frame.width, height: frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            root.layoutSubtreeIfNeeded()
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            try? "\(window.windowNumber)".write(toFile: path + ".wid", atomically: true, encoding: .utf8)
            // The measured slots, for the Windows card to match.
            let track = NSHostingView(rootView: StageTrack(current: .password, failed: false)).fittingSize
            try? "card \(size) track \(track) titles \(ConnectionCardContent.titlesHeight) band \(CardBand.size)"
                .write(toFile: path + ".metrics", atomically: true, encoding: .utf8)
            // Then the page with no tab (the sheep-cloud): the main window's number.
            AppModel.shared.closeCurrentWorkspace()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let main = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.frame.width > 400 }) {
                    try? "\(main.windowNumber)".write(toFile: path + ".main.wid", atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
#endif
