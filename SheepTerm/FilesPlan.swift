import Foundation

/// The Files tab's rules that need no UI: remote path arithmetic, listing
/// order, and what a name typed by the user may be. Pure, harness-tested
/// (`Tests/tests/FileServerTests.swift`).
nonisolated enum FilesPlan {
    static func defaultPort(_ proto: String) -> Int { ["ftp": 21, "tftp": 69][proto] ?? 22 }

    /// Open File…: the connect-box spelling of the form, nil when it is not a target.
    static func transferURL(proto: String, address: String, port: String, username: String) -> String? {
        let host = address.trimmingCharacters(in: .whitespaces)
        let user = proto == "tftp" ? "" : username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }),
              !user.contains(where: { $0.isWhitespace || $0 == "@" || $0 == ":" || $0 == "/" }) else { return nil }
        let portText = port.trimmingCharacters(in: .whitespaces)
        if !portText.isEmpty { guard let p = Int(portText), (1...65535).contains(p) else { return nil } }
        // A colon is only an IPv6 literal; "10.0.0.1:2222" belongs in Port.
        // (An IPv6 literal has at least two colons; "a.b.c.d:port" has one.)
        if host.contains(":") && !host.hasPrefix("["),
           host.filter({ $0 == ":" }).count < 2 || !ConnectParser.looksLikeIPv6(host) { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(proto)://\(user.isEmpty ? "" : user + "@")\(bracketed)\(portText.isEmpty ? "" : ":" + portText)"
    }


    /// `dir` + `name` with exactly one "/" between (remote paths are POSIX).
    static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty || dir == "." { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// The parent of a remote directory; "/" stays "/".
    static func parent(of path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "." }
        return slash == p.startIndex ? "/" : String(p[..<slash])
    }

    /// The Mac side's address bar: "~" / "~/x" from home, "/x" as is,
    /// anything else from the current folder; standardised ("a/../b").
    static func localFolder(_ typed: String, from current: URL, home: URL) -> URL? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if t.isEmpty || t == "~" { path = home.path }
        else if t.hasPrefix("~/") { path = home.appendingPathComponent(String(t.dropFirst(2))).path }
        else if t.hasPrefix("/") { path = t }
        else { path = current.appendingPathComponent(t).path }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Typed into the device side's address bar (SheepDrop's rules): blank,
    /// `~` = the login directory, `~/x` = under it, `/x` as is, anything else
    /// from the current directory; then `normalize`d.
    static func resolve(_ typed: String, from current: String, home: String = "/") -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if t.isEmpty || t == "~" { path = home }
        else if t.hasPrefix("~/") { path = join(home, String(t.dropFirst(2))) }
        else if t.hasPrefix("/") { path = t }
        else { path = join(current, t) }
        return normalize(path)
    }

    /// Collapses "//", "." and ".." in an absolute remote path (as SheepDrop):
    /// kept verbatim, "/a/b/.." made ↑ go back INTO /a/b and a trailing "/"
    /// gave "/a//x" on the next folder. A device path that is not absolute
    /// ("flash:/x", ".") is left alone.
    static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Whether ↑ has somewhere to go: not at "/" (as SheepDrop, the button
    /// is off there rather than listing "/" again).
    static func canGoUp(_ path: String) -> Bool { normalize(path) != "/" }

    /// Directories first, then names in Finder order (numbers by value).
    static func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        entries.filter { $0.name != "." && $0.name != ".." }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// A file or folder name the user typed (New Folder, Rename): one path
    /// component, no control characters. Nil = refuse.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !InvisibleFormatting.found(in: name) else { return nil }
        return name
    }

    /// A name from the REMOTE side becoming a file on this Mac: one plain
    /// component (a hostile server can list `../../x` or `a/b`). Nil = skip.
    /// A leading dot becomes "_" (a listing offering `.zshrc` must not
    /// land as a hidden file over the user's own); over 255 bytes = refuse.
    /// Invisible formatting (a bidi override hiding the real extension) is
    /// dropped, so the Mac shows the name in its true order.
    static func localName(forRemote name: String) -> String? {
        guard let valid = validName(InvisibleFormatting.stripped(name)), !valid.hasPrefix(".."), valid.utf8.count <= 255 else { return nil }
        return valid.hasPrefix(".") ? "_" + valid.dropFirst() : valid
    }

    /// The protocol a saved SSH host's Files tab uses: SFTP, with SCP when
    /// the device refuses the subsystem — `.scp` asks the engine for both.
    static let sshHostProto: RemoteEndpoint.Proto = .scp

    /// Where a Files tab's connection is.
    enum Phase: Equatable, Sendable {
        case connecting
        /// Not in known_hosts (or changed): ask before any credential goes.
        case hostKey(fingerprint: String, keyType: String, changed: Bool)
        /// The server wants a password and none is saved.
        case login(failed: Bool)
        case connected
        case failed(String)
    }

    /// Whether the tab reads "disconnected" (a red chip). A question on the
    /// card (host key, login) is still on the way in — blue, as an SSH tab
    /// asking the same; only a failure (or Cancel) is down.
    static func isDown(_ phase: Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    /// A node of the Files tab's connection card track: the SSH card's,
    /// with "Files" where SSH has "Terminal".
    enum CardNode: Equatable, Sendable { case connect, hostKey, user, password, files }

    /// The track for `proto`: FTP has no host key, TFTP no login.
    static func cardNodes(_ proto: RemoteEndpoint.Proto) -> [CardNode] {
        switch proto {
        case .sftp, .scp: return [.connect, .hostKey, .user, .password, .files]
        case .ftp: return [.connect, .user, .password, .files]
        case .tftp: return [.connect, .files]
        }
    }

    /// The node the card's `stage` lights (`.terminal` = Files); a stage the
    /// protocol has no node for lights the one before it.
    static func cardIndex(_ stage: ConnectionStage, in nodes: [CardNode]) -> Int {
        let order: [CardNode] = [.connect, .hostKey, .user, .password, .files]
        let wanted = min(stage.rawValue, order.count - 1)
        return nodes.lastIndex { order.firstIndex(of: $0)! <= wanted } ?? 0
    }

    /// The login the card asks: the username first while none is known,
    /// then the password (the SSH card's order, one question a page).
    static func loginStage(knownUsername: String) -> ConnectionStage {
        knownUsername.trimmingCharacters(in: .whitespaces).isEmpty ? .user : .password
    }

    /// What the tab chip says once connected.
    static func protocolLabel(_ proto: RemoteEndpoint.Proto, canBrowse: Bool) -> String {
        switch proto {
        case .sftp, .scp: return canBrowse ? "SFTP" : "SCP"
        case .ftp: return "FTP"
        case .tftp: return "TFTP"
        }
    }
}
