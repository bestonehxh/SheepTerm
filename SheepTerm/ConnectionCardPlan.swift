import Foundation

// What the connection card shows for each outcome of a login (§15) — pure,
// so the harness (`Tests/run.sh tests`) can pin it without SwiftUI: which
// stage, which red line under the field, which buttons, what Return does.
// `ConnectionPromptView` draws from it; `SSHTerminalController` decides
// with it whether a failure offers Try Again. Foundation only and in
// `sharedSources` (root Package.swift): SheepTerm for Windows compiles this
// same file for its card — ARCHITECTURE.md "Shared with Windows".

/// Which login a server refused: the tab's own host, or the jump host in
/// front of it. Set by `SSHWorker` when a session ends on a refused
/// credential; Try Again asks THAT login's password again.
public nonisolated enum RefusedLogin: Sendable, Equatable {
    case target, jumpHost
}

/// The stage track's nodes, Termius-style: connect → host key → user →
/// password → terminal.
public nonisolated enum ConnectionStage: Int, CaseIterable, Sendable {
    case connect, hostKey, user, password, terminal

    public var label: String {
        switch self {
        case .connect: return "Connect"
        case .hostKey: return "Host key"
        case .user: return "User"
        case .password: return "Password"
        case .terminal: return "Terminal"
        }
    }

    public var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .hostKey: return "key.fill"
        case .user: return "person.fill"
        case .password: return "lock.fill"
        case .terminal: return "terminal"
        }
    }
}

public nonisolated enum ConnectionCardPlan {
    /// The pane keeps this much around the card.
    public static let cardMargin: CGFloat = 24
    /// A pane lower than this never holds the card.
    public static let minPaneHeight: CGFloat = 260

    /// Whether the card (one size, every stage) fits in a pane of `pane`;
    /// if not it goes to the window-centred panel. One rule for every tab
    /// that shows the card (SSH, Files).
    public static func cardFits(card: CGSize, in pane: CGSize) -> Bool {
        pane.width >= card.width + cardMargin && pane.height >= max(minPaneHeight, card.height + cardMargin)
    }

    /// Whether a question from the worker may put a card up. Not after the tab stopped, and not after the user
    /// cancelled the connection: a reply that raced the Cancel click would raise a card for a stopped worker that
    /// nothing ever takes down (review 5.0 (20)). The same rule on Windows.
    public static func acceptsQuestion(stopped: Bool, cancelledByUser: Bool) -> Bool { !stopped && !cancelledByUser }

    /// What becomes of bytes headed for a session while its connection card is up (6.2 (8), Mac bug hunt SSH #1 / #6).
    /// The SSH worker accepts writes from the moment it starts and types them into the shell the moment it opens, so a
    /// password pasted a second time (⌘V on the host-key / Connecting… / Authenticating… page: the card has no paste,
    /// the menu action walks on to the terminal view under it) or keys typed while the card sat in its own panel landed
    /// on the device's command line, in its history and in the session log. Nothing passes while the card is up — any
    /// page, in the pane or in its panel: a typed key beeps; anything else (a paste that got this far, the terminal's
    /// own replies, a focus report as the card takes the keyboard) is dropped without a sound — before the shell opens
    /// nothing needs an answer. The card's own fields are not behind this: their field editor takes paste and typing
    /// itself. The same rule on Windows (58e0ee5) and Linux (b2c426a).
    public enum CardInput: Equatable, Sendable { case pass, refuse, refuseWithBeep }
    public static func outgoing(cardUp: Bool, typed: Bool) -> CardInput {
        guard cardUp else { return .pass }
        return typed ? .refuseWithBeep : .refuse
    }
    /// A paste (⌘V, Edit ▸ Paste, the terminal's menu) reaching the terminal view while the card is up: refused with a
    /// beep, before the planted-clipboard question or Safe Paste could put anything up over the card.
    public static func pasteAllowed(cardUp: Bool) -> Bool { !cardUp }

    /// A button of the card's row, left to right as drawn.
    public enum Button: Equatable, Sendable {
        case cancel
        /// "Connect" (a secret) / "Continue" (a username, a visible answer).
        case submit(String)
        case close
        case tryAgain
        case openKnownHosts
    }

    /// A text question's kind, as the card sees it.
    public enum Question: Equatable, Sendable {
        case username
        case password
        /// keyboard-interactive in the server's words (an OTP, a PIN).
        case challenge(secure: Bool)
    }

    public struct Page: Equatable, Sendable {
        public let stage: ConnectionStage
        /// The red line under the field ("Wrong password"), nil for none.
        public let note: String?
        public let buttons: [Button]
        /// What Return answers on the page.
        public let returnKey: Button

        public init(stage: ConnectionStage, note: String?, buttons: [Button], returnKey: Button) {
            self.stage = stage
            self.note = note
            self.buttons = buttons
            self.returnKey = returnKey
        }
    }

    /// A text question. `rejected`: the server turned down the last answer
    /// on this same connection and lets the user try again — the page is
    /// the same one, its field empty, with the red line.
    public static func question(_ question: Question, rejected: Bool) -> Page {
        let secure: Bool
        let stage: ConnectionStage
        switch question {
        case .username: secure = false; stage = .user
        case .password: secure = true; stage = .password
        case .challenge(let hidden): secure = hidden; stage = .password
        }
        let submit = Button.submit(secure ? "Connect" : "Continue")
        return Page(stage: stage, note: rejected ? rejectionNote(question) : nil,
                    buttons: [.cancel, submit], returnKey: submit)
    }

    /// One question page from the moment it is up until the next page
    /// replaces it. After an answer is submitted the page is `busy`: the
    /// primary button shows a spinner, the field and the button are off
    /// (a second Return / click answers nothing), and only Cancel works —
    /// it cancels the CONNECTION, since the worker already has the answer.
    /// Nothing here clears `busy` but a new page: the card makes a fresh
    /// `Entry` for every page it shows (rejection, next stage, failure) and
    /// takes the card down on a stop, so the spinner cannot stick.
    public struct Entry: Equatable, Sendable {
        public enum Submit: Equatable, Sendable {
            /// Send this to the worker; the page is busy now.
            case send(String)
            /// Nothing usable to send (an empty username / password).
            case refuseEmpty
            /// Already submitted, or not a text question.
            case ignored
        }
        public enum Cancel: Equatable, Sendable {
            /// Answer the question with "cancel" (the worker closes).
            case cancelQuestion
            /// The answer is already with the worker: cancel the connection.
            case cancelConnection
        }

        public let question: Question?
        public private(set) var busy = false

        public init(question: Question?) { self.question = question }

        /// `text` as typed. A username is trimmed; a password is not.
        public mutating func submit(_ text: String) -> Submit {
            guard let question, !busy else { return .ignored }
            let value: String
            switch question {
            case .username: value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .password, .challenge: value = text
            }
            switch question {
            case .username, .password:
                guard !value.isEmpty else { return .refuseEmpty }
            case .challenge:
                break
            }
            busy = true
            return .send(value)
        }

        public func cancel() -> Cancel {
            busy ? .cancelConnection : .cancelQuestion
        }
    }

    /// The red line for a re-asked question. A username is never "wrong"
    /// on its own (servers do not say), so it has none.
    public static func rejectionNote(_ question: Question) -> String? {
        switch question {
        case .username: return nil
        case .password: return "Wrong password"
        case .challenge: return "Not accepted — try again"
        }
    }

    /// The failure page at the stage the connection got to. Try Again is
    /// the default (Return) whenever it is offered; otherwise Return closes.
    public static func failure(at stage: ConnectionStage, offersKnownHosts: Bool, offersTryAgain: Bool) -> Page {
        var buttons: [Button] = [.close]
        if offersKnownHosts { buttons.append(.openKnownHosts) }
        if offersTryAgain { buttons.append(.tryAgain) }
        return Page(stage: stage, note: nil, buttons: buttons, returnKey: offersTryAgain ? .tryAgain : .close)
    }

    /// The password page's title: "user@name" — unless the name already
    /// starts with that login (a host opened from a typed `user@host` is
    /// NAMED "user@host", the tab chip shows it as is), so the card never
    /// says "admin@admin@10.0.0.1". The one place this rule lives.
    public static func passwordTitle(account: String, name: String) -> String {
        let user = account.split(separator: "@", maxSplits: 1).first.map(String.init) ?? account
        guard !user.isEmpty else { return name }
        if name.lowercased().hasPrefix(user.lowercased() + "@") { return name }
        return "\(user)@\(name)"
    }

    /// A failure only the host's settings can fix — the same connection
    /// again fails the same way: an out-of-range port (the host's or its
    /// jump host's, `SSHWorker`'s "invalid port …").
    public static func isConfigurationProblem(_ message: String) -> Bool {
        message.hasPrefix("invalid port ") || (message.hasPrefix("jump host ") && message.contains(": invalid port "))
    }

    /// Whether a failure is worth a Try Again (a fresh connection to the
    /// same host, from the start). Never for a host key that was refused,
    /// changed or revoked — connecting again only raises the same warning —
    /// nor for something only the user's settings can fix (a missing jump
    /// host), nor for the user's own Cancel.
    public static func offersTryAgain(message: String, hostKeyProblem: Bool, configurationProblem: Bool = false) -> Bool {
        if hostKeyProblem || configurationProblem || isConfigurationProblem(message) { return false }
        if message.hasPrefix("connection cancelled") { return false }
        return true
    }
}
