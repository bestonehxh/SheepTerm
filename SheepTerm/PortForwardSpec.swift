import Foundation

/// One SSH port forward as the user writes it (5.0 (49)) — ssh's own
/// spelling, stored as text in `Host.forwards`:
///   `8443:10.0.0.1:443`        127.0.0.1:8443 on this Mac → 10.0.0.1:443 as the server sees it (-L)
///   `8443:[2001:db8::1]:443`
///   `1080`                     a SOCKS proxy on 127.0.0.1:1080 through the server (-D)
///   `R9000:127.0.0.1:3000`     port 9000 on the SERVER → 127.0.0.1:3000 as this Mac sees it (-R)
///   `R0.0.0.0:9000:host:3000`  …listening on that server address (its GatewayPorts decides)
///   `R1080`                    a SOCKS proxy on the server whose connections leave from this Mac
/// A leading `-L`/`L`/`-D`/`D`/`-R`/`R` is accepted (pasted from an ssh
/// command line); -R needs its prefix, since three fields alone are -L.
/// The listen address on THIS Mac is always loopback: a bind address other
/// than 127.0.0.1/localhost/::1 for -L/-D is refused, never widened to the
/// network. (-R's bind address is on the server and is the user's to set.)
/// Pure — the harness runs it (`Tests/tests/PortForwardTests.swift`); the
/// worker turns it into SheepSSH's `ForwardRule`.
nonisolated enum PortForwardSpec: Equatable, Hashable, Sendable {
    case local(bindPort: Int, host: String, port: Int)
    case socks(bindPort: Int)
    /// `bindAddress` nil = the server's loopback (OpenSSH's default).
    /// `bindPort` 0 = the server picks one.
    case remote(bindAddress: String?, bindPort: Int, host: String, port: Int)
    case remoteSocks(bindAddress: String?, bindPort: Int)

    /// Forwards per host. More is a typo, not a plan.
    static let maximumPerHost = 16

    var bindPort: Int {
        switch self {
        case .local(let port, _, _), .socks(let port), .remote(_, let port, _, _), .remoteSocks(_, let port): return port
        }
    }

    /// Listens on the server, not on this Mac.
    var isRemote: Bool {
        switch self {
        case .remote, .remoteSocks: return true
        case .local, .socks: return false
        }
    }

    private static func bracketed(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    /// What is stored: the canonical spelling.
    var text: String {
        switch self {
        case .local(let bind, let host, let port): return "\(bind):\(Self.bracketed(host)):\(port)"
        case .socks(let bind): return String(bind)
        case .remote(let address, let bind, let host, let port):
            return "R" + (address.map { Self.bracketed($0) + ":" } ?? "") + "\(bind):\(Self.bracketed(host)):\(port)"
        case .remoteSocks(let address, let bind):
            return "R" + (address.map { Self.bracketed($0) + ":" } ?? "") + String(bind)
        }
    }

    /// What the form and the notices show (the same words as SheepSSH's
    /// `ForwardRule.label`, which the worker's notices use).
    var label: String {
        func remoteBind(_ address: String?, _ port: Int) -> String {
            address.map { "R \(Self.bracketed($0)):\(port)" } ?? "R \(port)"
        }
        switch self {
        case .local(let bind, let host, let port): return "\(bind) → \(Self.bracketed(host)):\(port)"
        case .socks(let bind): return "\(bind) SOCKS"
        case .remote(let address, let bind, let host, let port): return "\(remoteBind(address, bind)) → \(Self.bracketed(host)):\(port)"
        case .remoteSocks(let address, let bind): return "\(remoteBind(address, bind)) SOCKS"
        }
    }

    static func parse(_ raw: String) -> PortForwardSpec? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var forced: Character?
        // Only a real prefix: "localhost:1080" starts with an l too.
        for prefix in ["-L", "-D", "-R", "L", "D", "R", "l", "d", "r"] where text.hasPrefix(prefix) {
            guard let next = text.dropFirst(prefix.count).first, next.isNumber || next.isWhitespace || next == "[" else { continue }
            forced = Character(prefix.suffix(1).uppercased())
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }), let parts = split(text) else { return nil }
        if forced == "R" { return parseRemote(parts) }
        var fields = parts
        // An explicit loopback bind address is allowed and dropped.
        if fields.count == 2 || fields.count == 4 {
            guard ["127.0.0.1", "localhost", "::1"].contains(fields[0].lowercased()) else { return nil }
            fields.removeFirst()
        }
        guard let bind = port(fields[0]) else { return nil }
        switch fields.count {
        case 1:
            guard forced != "L" else { return nil }
            return .socks(bindPort: bind)
        case 3:
            guard forced != "D", let target = port(fields[2]), let host = targetHost(fields[1]) else { return nil }
            return .local(bindPort: bind, host: host, port: target)
        default:
            return nil
        }
    }

    /// `[address:]port[:host:hostport]` after an R. The server-side port may
    /// be 0 (the server picks).
    private static func parseRemote(_ parts: [String]) -> PortForwardSpec? {
        var fields = parts
        var address: String?
        if fields.count == 2 || fields.count == 4 {
            let a = fields.removeFirst()
            guard !a.isEmpty, !a.contains("@"), !a.contains("/") else { return nil }
            address = a
        }
        guard let bind = fields[0] == "0" ? 0 : port(fields[0]) else { return nil }
        switch fields.count {
        case 1:
            return .remoteSocks(bindAddress: address, bindPort: bind)
        case 3:
            guard let target = port(fields[2]), let host = targetHost(fields[1]) else { return nil }
            return .remote(bindAddress: address, bindPort: bind, host: host, port: target)
        default:
            return nil
        }
    }

    private static func targetHost(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains("@"), !text.contains("/") else { return nil }
        return text
    }

    /// Colon-separated fields, a `[v6]` kept whole (brackets removed).
    private static func split(_ text: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inBracket = false
        for ch in text {
            switch ch {
            case "[":
                guard !inBracket, current.isEmpty else { return nil }
                inBracket = true
            case "]":
                guard inBracket else { return nil }
                inBracket = false
            case ":" where !inBracket:
                fields.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        guard !inBracket else { return nil }
        fields.append(current)
        return fields
    }

    private static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
              (1...65535).contains(value) else { return nil }
        return value
    }

    /// Two forwards that would want the same listening port — on this Mac,
    /// or on the server (port 0 never clashes: the server picks).
    func clashes(with other: PortForwardSpec) -> Bool {
        isRemote == other.isRemote && bindPort == other.bindPort && bindPort != 0
    }

    /// Why a typed forward cannot be added to `existing`, or nil if it can.
    static func problem(adding spec: PortForwardSpec, to existing: [PortForwardSpec]) -> String? {
        if existing.count >= maximumPerHost { return String(localized: "At most \(maximumPerHost) forwards") }
        if existing.contains(where: { $0.clashes(with: spec) }) {
            return String(localized: "Port \(String(spec.bindPort)) is already forwarded")
        }
        return nil
    }
}

extension Host {
    /// The forwards that parse, in order, without a repeated listen port.
    /// What does not parse (a hand edit, another build) is skipped here;
    /// the worker says so at connect time.
    var forwardSpecs: [PortForwardSpec] {
        var kept: [PortForwardSpec] = []
        for spec in (forwards ?? []).compactMap(PortForwardSpec.parse) where !kept.contains(where: { $0.clashes(with: spec) }) {
            kept.append(spec)
        }
        return kept
    }
}

// MARK: - Easy form (5.0 (50), the user: "make port forwarding easy")

nonisolated extension PortForwardSpec {
    /// The list's words: where it listens, where it goes.
    var displayLabel: String {
        func target(_ host: String, _ port: Int) -> String { "\(Self.bracketed(host)):\(port)" }
        switch self {
        case .local(let bind, let host, let port):
            return String(localized: "Mac :\(String(bind)) → \(target(host, port))")
        case .socks(let bind):
            return String(localized: "SOCKS on Mac :\(String(bind))")
        case .remote(let address, let bind, let host, let port):
            let listen = address.map { "\(Self.bracketed($0)):\(bind)" } ?? ":\(bind)"
            return String(localized: "Server \(listen) → \(target(host, port))")
        case .remoteSocks(let address, let bind):
            let listen = address.map { "\(Self.bracketed($0)):\(bind)" } ?? ":\(bind)"
            return String(localized: "SOCKS on server \(listen)")
        }
    }

    var isSOCKS: Bool {
        switch self {
        case .socks, .remoteSocks: return true
        case .local, .remote: return false
        }
    }

    /// The address a local forward is used at, on this Mac.
    var macAddress: String? {
        switch self {
        case .local(let bind, _, _), .socks(let bind): return "127.0.0.1:\(bind)"
        case .remote, .remoteSocks: return nil
        }
    }

    /// What "Open in Web Tab" opens for a local forward: https for the
    /// ports a device's web UI lives on behind TLS, http otherwise.
    var webURL: String? {
        guard case .local(let bind, _, let port) = self else { return nil }
        let tls: Set<Int> = [443, 8443, 4443, 9443, 10443]
        return (tls.contains(port) || tls.contains(bind) ? "https" : "http") + "://127.0.0.1:\(bind)/"
    }
}

/// One forward of a live SSH session, as the status bar menu shows it
/// (5.0 (53)): listening or stopped, and how many connections it carries.
nonisolated struct ForwardState: Equatable, Hashable, Sendable {
    let spec: PortForwardSpec
    let active: Bool
    let connections: Int

    /// The menu section's title: the forward, then what it is doing.
    var title: String {
        if !active { return String(localized: "\(spec.displayLabel) — stopped") }
        if connections == 0 { return spec.displayLabel }
        return connections == 1 ? String(localized: "\(spec.displayLabel) — 1 connection")
                                : String(localized: "\(spec.displayLabel) — \(connections) connections")
    }
}

/// The add form behind the forwards row's +: three choices and plain fields
/// instead of ssh's spelling (which still works pasted into Host).
nonisolated struct ForwardDraft: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case local, remote, socks }
    var kind: Kind = .local
    /// The listening port: on this Mac (local, SOCKS) or on the server (remote).
    var listenPort = ""
    var host = ""
    var targetPort = ""
    /// The listening port was typed by the user: stop suggesting one.
    var listenPortEdited = false

    var isEmpty: Bool {
        listenPort.trimmingCharacters(in: .whitespaces).isEmpty && host.trimmingCharacters(in: .whitespaces).isEmpty
            && targetPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The listening port to suggest for a target port: the same port when
    /// it is a free-to-bind one, a familiar high twin below 1024
    /// (443 → 8443, 80 → 8080, 22 → 2222, 23 → 2323).
    static func suggestedListenPort(for target: Int) -> Int {
        switch target {
        case 22: return 2222
        case 23: return 2323
        case 1..<1024: return target + 8000
        default: return target
        }
    }

    /// The target port changed: fill the listening port unless it was typed
    /// — the next free one when the suggestion is taken by `existing`.
    mutating func targetPortChanged(avoiding existing: [PortForwardSpec] = []) {
        guard !listenPortEdited, kind != .socks,
              let port = Int(targetPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return }
        var listen = Self.suggestedListenPort(for: port)
        let remote = kind == .remote
        while listen < 65535, existing.contains(where: { $0.isRemote == remote && $0.bindPort == listen }) { listen += 1 }
        listenPort = String(listen)
    }

    /// ssh's spelling pasted into Host (`-L 8443:10.0.0.1:443`, `R9000:h:3000`,
    /// `-D 1080`): the form takes it apart. Returns whether it did.
    @discardableResult
    mutating func absorbPasted(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A plain host name or address is not ssh spelling.
        let looksLikeSpec = trimmed.filter { $0 == ":" }.count >= 2 && trimmed.first.map { $0.isNumber || "-LRDlrd[".contains($0) } == true
        guard looksLikeSpec || trimmed.hasPrefix("-"), let spec = PortForwardSpec.parse(trimmed) else { return false }
        listenPortEdited = true
        switch spec {
        case .local(let bind, let h, let p): (kind, listenPort, host, targetPort) = (.local, String(bind), h, String(p))
        case .remote(_, let bind, let h, let p): (kind, listenPort, host, targetPort) = (.remote, String(bind), h, String(p))
        case .socks(let bind), .remoteSocks(_, let bind): (kind, listenPort, host, targetPort) = (.socks, String(bind), "", "")
        }
        return true
    }

    /// The forward these fields describe, or nil while incomplete/invalid.
    var spec: PortForwardSpec? {
        let listen = Int(listenPort.trimmingCharacters(in: .whitespaces))
        let target = Int(targetPort.trimmingCharacters(in: .whitespaces))
        let h = host.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let listen, (1...65535).contains(listen) else { return nil }
        switch kind {
        case .socks:
            return .socks(bindPort: listen)
        case .local, .remote:
            guard let target, (1...65535).contains(target), !h.isEmpty,
                  !h.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" }) else { return nil }
            return kind == .local ? .local(bindPort: listen, host: h, port: target)
                                  : .remote(bindAddress: nil, bindPort: listen, host: h, port: target)
        }
    }

    /// The red line under the form: nothing while empty, a short reason
    /// once something is typed and it cannot be added.
    func error(adding existing: [PortForwardSpec]) -> String? {
        guard !isEmpty else { return nil }
        guard let spec else {
            return kind == .socks ? String(localized: "Port must be 1-65535")
                                  : String(localized: "Enter a port, a host and its port")
        }
        return PortForwardSpec.problem(adding: spec, to: existing)
    }

    /// The form's forward when it can be added to `existing`.
    func addable(to existing: [PortForwardSpec]) -> PortForwardSpec? {
        guard let spec, PortForwardSpec.problem(adding: spec, to: existing) == nil else { return nil }
        return spec
    }
}

nonisolated extension PortForwardSpec {
    /// What a form ended with is stored as: a complete, valid draft still
    /// open (never confirmed with ✓) counts too.
    static func stored(_ forwards: [PortForwardSpec], draft: ForwardDraft?) -> [String]? {
        var all = forwards
        if let spec = draft?.addable(to: forwards) { all.append(spec) }
        return all.isEmpty ? nil : all.map(\.text)
    }
}
