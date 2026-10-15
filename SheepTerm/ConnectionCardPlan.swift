import Foundation

// What the connection card shows for each outcome of a login (§15) — pure,
// so the harness (`Tests/run.sh tests`) can pin it without SwiftUI: which
// stage, which red line under the field, which buttons, what Return does.
// `ConnectionPromptView` draws from it; `SSHTerminalController` decides
// with it whether a failure offers Try Again.

/// Which login a server refused: the tab's own host, or the jump host in
/// front of it. Set by `SSHWorker` when a session ends on a refused
/// credential; Try Again asks THAT login's password again.
nonisolated enum RefusedLogin: Sendable, Equatable {
    case target, jumpHost
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

enum ConnectionCardPlan {
    /// A button of the card's row, left to right as drawn.
    enum Button: Equatable {
        case cancel
        /// "Connect" (a secret) / "Continue" (a username, a visible answer).
        case submit(String)
        case close
        case tryAgain
        case openKnownHosts
    }

    /// A text question's kind, as the card sees it.
    enum Question: Equatable {
        case username
        case password
        /// keyboard-interactive in the server's words (an OTP, a PIN).
        case challenge(secure: Bool)
    }

    struct Page: Equatable {
        let stage: ConnectionStage
        /// The red line under the field ("Wrong password"), nil for none.
        let note: String?
        let buttons: [Button]
        /// What Return answers on the page.
        let returnKey: Button
    }

    /// A text question. `rejected`: the server turned down the last answer
    /// on this same connection and lets the user try again — the page is
    /// the same one, its field empty, with the red line.
    static func question(_ question: Question, rejected: Bool) -> Page {
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

    /// The red line for a re-asked question. A username is never "wrong"
    /// on its own (servers do not say), so it has none.
    static func rejectionNote(_ question: Question) -> String? {
        switch question {
        case .username: return nil
        case .password: return "Wrong password"
        case .challenge: return "Not accepted — try again"
        }
    }

    /// The failure page at the stage the connection got to. Try Again is
    /// the default (Return) whenever it is offered; otherwise Return closes.
    static func failure(at stage: ConnectionStage, offersKnownHosts: Bool, offersTryAgain: Bool) -> Page {
        var buttons: [Button] = [.close]
        if offersKnownHosts { buttons.append(.openKnownHosts) }
        if offersTryAgain { buttons.append(.tryAgain) }
        return Page(stage: stage, note: nil, buttons: buttons, returnKey: offersTryAgain ? .tryAgain : .close)
    }

    /// The password page's title: "user@name" — unless the name already
    /// starts with that login (a host opened from a typed `user@host` is
    /// NAMED "user@host", the tab chip shows it as is), so the card never
    /// says "admin@admin@10.0.0.1". The one place this rule lives.
    static func passwordTitle(account: String, name: String) -> String {
        let user = account.split(separator: "@", maxSplits: 1).first.map(String.init) ?? account
        guard !user.isEmpty else { return name }
        if name.lowercased().hasPrefix(user.lowercased() + "@") { return name }
        return "\(user)@\(name)"
    }

    /// A failure only the host's settings can fix — the same connection
    /// again fails the same way: an out-of-range port (the host's or its
    /// jump host's, `SSHWorker`'s "invalid port …").
    static func isConfigurationProblem(_ message: String) -> Bool {
        message.hasPrefix("invalid port ") || (message.hasPrefix("jump host ") && message.contains(": invalid port "))
    }

    /// Whether a failure is worth a Try Again (a fresh connection to the
    /// same host, from the start). Never for a host key that was refused,
    /// changed or revoked — connecting again only raises the same warning —
    /// nor for something only the user's settings can fix (a missing jump
    /// host), nor for the user's own Cancel.
    static func offersTryAgain(message: String, hostKeyProblem: Bool, configurationProblem: Bool = false) -> Bool {
        if hostKeyProblem || configurationProblem || isConfigurationProblem(message) { return false }
        if message.hasPrefix("connection cancelled") { return false }
        return true
    }
}
