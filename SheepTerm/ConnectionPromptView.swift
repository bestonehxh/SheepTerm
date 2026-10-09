import AppKit
import Combine
import SwiftUI

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

/// The stage track's nodes, Termius-style: connect → host key → user →
/// password → terminal.
enum ConnectionStage: Int, CaseIterable {
    case connect, hostKey, user, password, terminal

    var label: String {
        switch self {
        case .connect: return "Connect"
        case .hostKey: return "Host key"
        case .user: return "User"
        case .password: return "Password"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .hostKey: return "key.fill"
        case .user: return "person.fill"
        case .password: return "lock.fill"
        case .terminal: return "terminal"
        }
    }
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
}

/// The card's header: the session's title and "SSH address:port".
struct ConnectionCardHeader {
    let title: String
    let subtitle: String
    /// "name — address", the title of the window-centred form (narrow pane).
    let windowTitle: String
}

/// What the card shows below the stage track.
enum ConnectionCardPage {
    /// "Connecting…" / "Authenticating…" with a spinner; Close cancels the
    /// connection.
    case progress(String)
    /// One of the worker's questions.
    case question(ConnectionPrompt)
    /// The connection failed: the reason in red, Close (and, for a pinned
    /// key that no longer matches, Open Known Hosts…).
    case failure(title: String, message: String, hostKeyProblem: Bool, offersKnownHosts: Bool)
}

/// What the user did on the card.
enum ConnectionCardAction {
    case answer(ConnectionPromptReply)
    /// Close on a progress or failure page (Escape too).
    case close
    case openKnownHosts
}

/// What the card shows, observed by `ConnectionCardContent`.
@MainActor
final class ConnectionCardModel: ObservableObject {
    @Published var header: ConnectionCardHeader
    @Published var stage: ConnectionStage = .connect
    @Published var page: ConnectionCardPage = .progress("Connecting…")
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

    func escape() {
        if case .question = page { send(.answer(.cancel)) } else { send(.close) }
    }

    var hasField: Bool {
        if case .question(let prompt) = page, case .hostKey = prompt.step { return false }
        if case .question = page { return true }
        return false
    }
}

/// The card a session shows while it connects (4.2 (9)) — the EXISTING
/// popups put in the tab (the user's word: "เอาของ popup เดิมมาเลย"): the
/// same glass (`popupChrome`), width, title/text layout, text entry
/// (`PopupTextEntry`), fingerprint block (`FingerprintBlock`) and buttons as
/// AuthPromptView / HostKeyPromptView. Two additions only: the app icon
/// carries a small badge for the stage, and the stage track sits under the
/// titles. Every stage has the same frame (the tallest page's), content
/// centred, so nothing jumps between steps.
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
    /// The card's width, every stage (content column 444 + 2 × 28).
    static let cardWidth: CGFloat = 500

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
    func show(stage: ConnectionStage, page: ConnectionCardPage, action: @escaping (ConnectionCardAction) -> Void) {
        let hadKeyboard = hasKeyboard
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
            case .failure: model.send(.close)
            case .question: model.send(.answer(.cancel))
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

/// The SwiftUI side of the card: the popups' layout with the badge and the
/// stage track.
struct ConnectionCardContent: View {
    @ObservedObject var model: ConnectionCardModel

    var body: some View {
        VStack(spacing: 18) {
            // The password popup's round sheep (the user's pick), its badge
            // naming the stage.
            SheepLockBadge(symbol: badge?.symbol, danger: badge?.danger ?? false)
                .frame(width: 64, height: 64)
            titles
            StageTrack(current: model.stage, failed: isFailure)
            // Not `.id(pageID)`-swapped: replacing the whole page re-created
            // the glass and flickered between steps (the user, 2026-10-09).
            // Pages switch in place, without animation; the entry page
            // resets its own text on `pageID`.
            pageBody
                .transaction { $0.animation = nil }
        }
        .padding(28)
        .padding(.top, model.inPanel ? ConnectionCardView.panelTitleBand : 0)
        // Wider than SheepAlert (the user's call, 2026-10-09): landscape, so
        // the fingerprint sits on one line and the fixed height — set by
        // this page — stays low; every stage shares it.
        .frame(width: ConnectionCardView.cardWidth)
        // `popupChrome` adds 10 pt each side around this frame.
        .frame(height: model.fixedHeight.map { $0 - 20 + (model.inPanel ? ConnectionCardView.panelTitleBand : 0) },
               alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { model.onTap?() }
        .onExitCommand { model.escape() }
        .popupChrome()
    }

    private var isFailure: Bool {
        if case .failure = model.page { return true }
        return false
    }

    private var hostKeyProblem: Bool {
        if case .failure(_, _, let problem, _) = model.page { return problem }
        return false
    }

    /// The stage's badge: none while connecting; red only for a key that no
    /// longer matches (or was refused).
    private var badge: AppIconBadge.Badge? {
        switch model.page {
        case .progress: return nil
        case .question(let prompt):
            switch prompt.step {
            case .username: return .init(symbol: "person.fill")
            case .hostKey: return .init(symbol: "key.fill")
            case .password, .challenge: return .init(symbol: "lock.fill")
            }
        case .failure(_, _, let problem, _):
            return .init(symbol: "exclamationmark.triangle.fill", danger: problem)
        }
    }

    /// The popups' text block (15 pt semibold title, 12 pt secondary lines,
    /// centred) naming the host: its name as the title — "user@name" on the
    /// password page — and "SSH address:port" under it; the bastion's while
    /// the question is the jump host's.
    @ViewBuilder private var titles: some View {
        VStack(spacing: 4) {
            switch model.page {
            case .progress(let text):
                title(model.header.title)
                secondary(model.header.subtitle)
                secondary(text)
            case .question(let prompt):
                let name = prompt.viaJump ? prompt.host : model.header.title
                let endpoint = prompt.viaJump ? "jump host for \(prompt.tabHost)" : model.header.subtitle
                switch prompt.step {
                case .hostKey(let question):
                    title(prompt.viaJump ? question.target : name)
                    secondary(endpoint)
                    // One line at the card's width — a wrapped second line
                    // centred under the first read badly (the user, 2026-10-09).
                    Text("First connection — compare the fingerprint before you trust it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.9)
                        .padding(.top, 2)
                case .password(let account):
                    let user = account.split(separator: "@", maxSplits: 1).first.map(String.init) ?? account
                    title("\(user)@\(name)")
                    secondary(endpoint)
                case .challenge(let text, _):
                    title(name)
                    secondary(endpoint)
                    secondary(text).lineLimit(3)
                case .username:
                    title(name)
                    secondary(endpoint)
                }
            case .failure(let heading, let message, let problem, _):
                Text(heading).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(problem ? Color(nsColor: SheepAlert.destructiveRed) : Color.primary)
                    .multilineTextAlignment(.center)
                secondary(model.header.subtitle)
                // A paragraph: its lines start under each other, not centred.
                secondary(message).lineLimit(4).multilineTextAlignment(.leading).textSelection(.enabled)
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
    }

    private func secondary(_ text: String) -> Text {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    /// Every page is the same two bands — a content band of one fixed height
    /// (the fingerprint block, the tallest, sets it) and the button row — so
    /// the buttons sit at exactly the same place on every step (the user,
    /// 2026-10-09) and nothing moves between steps.
    @ViewBuilder private var pageBody: some View {
        switch model.page {
        case .progress:
            CardPage(content: { ProgressView().controlSize(.small) },
                     buttons: { CardButton("Cancel", role: .neutral, help: "Cancel the connection (Esc)") { model.escape() } })
        case .question(let prompt):
            if case .hostKey(let question) = prompt.step {
                HostKeyPage(model: model, question: question)
            } else {
                EntryPage(model: model, prompt: prompt)
            }
        case .failure(_, _, _, let offersKnownHosts):
            CardPage(content: { EmptyView() }, buttons: {
                if offersKnownHosts {
                    CardButton("Open Known Hosts…", role: .accent, help: "Review the saved key") { model.send(.openKnownHosts) }
                }
                CardButton("Close", role: .neutral, help: "Close this message") { model.send(.close) }
            })
        }
    }
}

/// The two bands of a card page: content (fixed height, centred) and the
/// button row (one capsule height, centred, equal-width buttons).
private struct CardPage<Content: View, Buttons: View>: View {
    /// Tall enough for the fingerprint block (label + boxed line).
    static var contentHeight: CGFloat { 60 }
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 18) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: Self.contentHeight)
            HStack(spacing: 8) { buttons() }
                .frame(height: 30)
        }
    }
}

/// One capsule button of the card's row — the popup's TrustButtonStyle in
/// three fills (neutral / accent / green), one minimum width so a row of
/// one, two or three buttons lines up the same way on every page.
private struct CardButton: View {
    enum Role { case neutral, accent, green, caution }
    let title: String
    let role: Role
    let help: String
    let action: () -> Void

    init(_ title: String, role: Role, help: String, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).frame(minWidth: 96).padding(.horizontal, 10) }
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

    private var answer: String {
        if case .username = prompt.step { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    private func submit() {
        switch prompt.step {
        case .username, .password:
            // Empty is not an answer the worker can use (it would close the
            // session as cancelled) — Escape cancels; Return on empty says no.
            guard !answer.isEmpty else { NSSound.beep(); return }
        default:
            break
        }
        let value = answer
        text = ""
        model.send(.answer(.text(value)))
    }

    var body: some View {
        CardPage(content: {
            // The popup's own width for the field (the user's call: a
            // username or password does not need the wide card's full line).
            PopupTextEntry(placeholder: placeholder, secure: prompt.isSecure, text: $text,
                           focusTrigger: model.focusRequest, focusOnAppear: model.focusOnAppear,
                           onSubmit: submit) { focused in
                if focused { model.onFocus?() }
            }
            .frame(width: SheepAlert.contentWidth)
            .id(model.pageID)
        }, buttons: {
            CardButton("Cancel", role: .neutral, help: "Cancel the connection (Esc)") { model.escape() }
            CardButton(prompt.isSecure ? "Connect" : "Continue", role: .green, help: "Return", action: submit)
        })
        .onChange(of: model.pageID) { _, _ in text = "" }
    }

    private var placeholder: String {
        switch prompt.step {
        case .username: return "Username"
        case .password: return "Password"
        case .challenge(_, let secure): return secure ? "Answer (hidden)" : "Answer"
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
            FingerprintBlock(keyType: HostKeyPromptView.keyTypeLabel(question.keyType), fingerprint: base64, oneLine: true)
        }, buttons: {
            // Cancel · Connect Once · Trust & Connect. Trust is green and
            // takes a deliberate click — Return and Escape answer Cancel (the
            // card's keyDown) and no button takes the keyboard's focus.
            CardButton("Cancel", role: .neutral,
                       help: "Don't trust this key — the connection is cancelled and nothing is saved (Return / Esc)") { model.send(.answer(.cancel)) }
            CardButton("Connect Once", role: .caution,
                       help: "Connect this time only — the key is not saved and the next connection asks again") { model.send(.answer(.trustOnce)) }
            CardButton("Trust & Connect", role: .green, help: "Save this key to known_hosts and connect") { model.send(.answer(.trust)) }
        })
    }
}

/// The app icon at the popups' 64 pt with a small round badge on its
/// bottom-right edge naming the stage (the user's picture): a dark disc with
/// a lighter rim and a soft shadow, the symbol in the icon's own cream so the
/// two read as one piece; red only for a host key that no longer matches.
struct AppIconBadge: View {
    struct Badge {
        let symbol: String
        var danger = false
    }
    let badge: Badge?

    /// The cream of the app icon's centre.
    static let cream = Color(red: 0.96, green: 0.90, blue: 0.80)

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    ZStack {
                        Circle().fill(Color(nsColor: NSColor(Theme.tabActive)))
                        Circle().stroke(Color.white.opacity(0.22), lineWidth: 1)
                        Image(systemName: badge.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(badge.danger ? Color(nsColor: SheepAlert.destructiveRed) : Self.cream)
                    }
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: 4, y: 3)
                }
            }
    }
}

/// The stage track: Connect · Host key · User · Password · Terminal —
/// 24 pt nodes with a 10 pt label under each (the current one brighter).
/// Reached nodes in the accent, the line filled up to the current node,
/// future nodes grey; a failure paints the current node red.
struct StageTrack: View {
    let current: ConnectionStage
    let failed: Bool
    private static let node: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ConnectionStage.allCases, id: \.rawValue) { stage in
                if stage != .connect {
                    Rectangle()
                        .fill(stage.rawValue <= current.rawValue ? Theme.accent : Theme.controlFill)
                        .frame(height: 3)
                        .padding(.top, (Self.node - 3) / 2)
                }
                column(stage)
            }
        }
        // The edge labels hang past the first and last node.
        .padding(.horizontal, 12)
    }

    private func column(_ stage: ConnectionStage) -> some View {
        let reached = stage.rawValue <= current.rawValue
        let fill: Color = stage == current && failed ? Color(nsColor: SheepAlert.destructiveRed)
            : (reached ? Theme.accent : Theme.controlFill)
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(fill)
                if stage == current {
                    Circle().stroke(fill.opacity(0.45), lineWidth: 1.5).padding(-3)
                }
                Image(systemName: stage.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(reached ? Color.white : Theme.dimText)
            }
            .frame(width: Self.node, height: Self.node)
            Text(stage.label)
                .font(.system(size: 10, weight: stage == current ? .semibold : .regular))
                .foregroundStyle(stage == current ? Color.primary : Color.secondary)
                .fixedSize()
                .frame(width: Self.node)
        }
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
    var veiled = true {
        didSet {
            guard veiled != oldValue else { return }
            layer?.backgroundColor = veiled ? NSColor.black.withAlphaComponent(0.45).cgColor : nil
            window?.invalidateCursorRects(for: self)
        }
    }
    weak var card: ConnectionCardView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        autoresizingMask = [.width, .height]
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

