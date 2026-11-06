import Foundation

/// Import and export of saved SSH hosts (6.0 (57), the user: "JSON, CSV and
/// OpenSSH ~/.ssh/config"). Pure text in, text out — the harness checks it
/// (`Tests/tests/HostListCodecTests.swift`).
///
/// Never a secret: no password, no key, no credential id goes out — only
/// what `ssh` itself would need (name, address, port, user) and where the
/// host sits (its group path, its type, its jump host). An import lands in
/// Add Hosts as rows to look over first, through the very parser a paste
/// uses (`sheetText`), so nothing is saved until the user presses Add.
/// `~/.ssh/config` is never read on its own (CLAUDE.md): only a file the
/// user picks.
nonisolated enum HostListCodec {
    struct Entry: Equatable, Sendable {
        var name: String
        var address: String
        var port: Int = 22
        var user: String = ""
        /// `HostType.rawValue` — "ssh", "server", "jump" …
        var type: String = "ssh"
        /// "Parent/Child"; "" = top level.
        var group: String = ""
        /// A saved host's name or user@host[:port]; nil = direct.
        var jump: String? = nil
        /// Export only, never written to a file: the saved host this entry
        /// is, and the saved bastion it goes through — so an ssh config's
        /// ProxyJump names the very block its bastion got (Fable round 10).
        var id: UUID? = nil
        var jumpID: UUID? = nil
    }

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case json, csv, sshConfig
        var id: String { rawValue }
        var label: String {
            switch self {
            case .json: "JSON"
            case .csv: "CSV"
            case .sshConfig: "OpenSSH config"
            }
        }
        var fileName: String {
            switch self {
            case .json: "SheepTerm Hosts.json"
            case .csv: "SheepTerm Hosts.csv"
            case .sshConfig: "config"
            }
        }
    }

    // MARK: Export

    /// Every saved SSH host (Jump Servers and labels included), in sidebar
    /// order. `username`: the host's own, else its credential's — a name is
    /// not a secret; the password it unlocks never leaves the Keychain.
    @MainActor static func entries(groups: [HostGroup], username: (Host) -> String) -> [Entry] {
        let all = groups.flatMap(\.hosts)
        return GroupTree.preorder(groups).flatMap { group, _ -> [Entry] in
            let path = GroupTree.path(of: group.id, in: groups).joined(separator: "/")
            return group.hosts.filter { $0.kind == .ssh }.map { host in
                var entry = Entry(name: host.name, address: host.address, port: host.port, user: username(host),
                                  type: host.hostType?.rawValue ?? "ssh", group: path, id: host.id)
                switch JumpTarget.resolve(host: host, saved: all, groups: groups) {
                case .saved(let bastion): entry.jump = bastion.name; entry.jumpID = bastion.id
                case .spec(let bastion): entry.jump = target(Entry(name: "", address: bastion.address, port: bastion.port, user: bastion.username))
                case .none, .invalid: break
                }
                return entry
            }
        }
    }

    static func export(_ entries: [Entry], as format: Format) -> String {
        switch format {
        case .json: json(entries)
        case .csv: csv(entries)
        case .sshConfig: sshConfig(entries)
        }
    }

    static func json(_ entries: [Entry]) -> String {
        let list: [[String: Any]] = entries.map { e in
            var object: [String: Any] = ["name": e.name, "host": e.address, "port": e.port, "type": e.type]
            if !e.user.isEmpty { object["user"] = e.user }
            if !e.group.isEmpty { object["group"] = e.group }
            if let jump = e.jump, !jump.isEmpty { object["jump"] = jump }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
    }

    /// The columns Add Hosts reads back (`BulkHostParser.headingColumns`):
    /// the user and port ride in the Host cell as user@host:port.
    static func csv(_ entries: [Entry]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["Name,Host / IP,Group,Type"]
        for e in entries { lines.append([e.name, target(e), e.group, e.type].map(field).joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `Host <alias>` blocks; the alias is the name with what ssh would not
    /// take (spaces, wildcards) turned into "-".
    static func sshConfig(_ entries: [Entry]) -> String {
        var out = ["# Exported from SheepTerm — no passwords or keys."]
        // First every block's alias, then the blocks: a ProxyJump to a saved
        // bastion names the alias THAT block got, "-2" and all.
        var taken = Set<String>()
        var aliases: [String] = []
        var aliasOfID: [UUID: String] = [:]
        for e in entries {
            var alias = alias(for: e.name.isEmpty ? e.address : e.name)
            if taken.contains(alias.lowercased()) {
                var n = 2
                while taken.contains("\(alias)-\(n)".lowercased()) { n += 1 }
                alias = "\(alias)-\(n)"
            }
            taken.insert(alias.lowercased())
            aliases.append(alias)
            if let id = e.id { aliasOfID[id] = alias }
        }
        for (e, alias) in zip(entries, aliases) {
            out.append("")
            out.append("Host \(alias)")
            out.append("    HostName \(quoted(e.address))")
            if !e.user.isEmpty { out.append("    User \(quoted(e.user))") }
            if e.port != 22 { out.append("    Port \(e.port)") }
            if let jump = e.jump, !jump.isEmpty {
                // A saved bastion by its block's alias; a typed one as typed.
                let hop = e.jumpID.flatMap { aliasOfID[$0] } ?? (e.jumpID == nil ? jump : self.alias(for: jump))
                out.append("    ProxyJump \(quoted(hop))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A value ssh reads whole: in double quotes when it holds a space, a
    /// "#", a quote of either kind or a backslash (a user "john doe" unquoted
    /// made ssh refuse the file; so did "o'brien" — ssh quotes with ' too —
    /// and a bare "dom\user" reached ssh as "domuser"-ish; Fable round 13).
    static func quoted(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard clean.contains(where: { $0.isWhitespace || $0 == "#" || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return clean }
        // ssh reads \" inside quotes as a quote (Fable round 11): kept exact.
        return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func alias(for name: String) -> String {
        let allowed: (Character) -> Bool = { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        let mapped = String(name.trimmingCharacters(in: .whitespaces).map { allowed($0) ? $0 : "-" })
        let squeezed = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return squeezed.isEmpty ? "host" : squeezed
    }

    /// user@host:port as Add Hosts writes it; an IPv6 address in brackets.
    static func target(_ e: Entry) -> String {
        let host = e.address.contains(":") && !e.address.hasPrefix("[") ? "[\(e.address)]" : e.address
        return (e.user.isEmpty ? "" : e.user + "@") + host + (e.port == 22 || e.port <= 0 ? "" : ":\(e.port)")
    }

    // MARK: Import

    /// JSON when it starts like JSON, an ssh config when it has `Host` blocks,
    /// else the CSV / pasted-table path Add Hosts already has.
    static func detect(_ text: String) -> Format {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "[" alone is not JSON: a CSV can start with "[2001:db8::1]:22".
        if (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")), entries(fromJSON: trimmed) != nil { return .json }
        // `scan`, not `keyword`: a Host line with an unclosed quote is still a
        // Host line — the file goes the ssh-config way and is refused with its
        // line number (Fable round 17).
        let keys = Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            scan(String(line))?.key
        })
        return keys.contains("host") && !keys.isDisjoint(with: ["hostname", "user", "port", "proxyjump", "identityfile"]) ? .sshConfig : .csv
    }

    /// An array of objects, or `{"hosts": [...]}`. Keys in any case:
    /// name/label/alias, host/hostname/address/ip, port, user/username,
    /// type/kind, group/folder/path, jump/proxyjump. nil = not that shape.
    static func entries(fromJSON text: String) -> [Entry]? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [Any]
        if let array = root as? [Any] { list = array }
        else if let object = root as? [String: Any], let hosts = object.first(where: { $0.key.lowercased() == "hosts" })?.value as? [Any] { list = hosts }
        else { return nil }
        return list.compactMap { item -> Entry? in
            guard let raw = item as? [String: Any] else { return nil }
            var object: [String: Any] = [:]
            for (key, value) in raw { object[key.lowercased()] = value }
            func text(_ keys: [String]) -> String? {
                for key in keys {
                    if let s = object[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) }
                    if let n = object[key] as? NSNumber { return n.stringValue }
                }
                return nil
            }
            guard let address = text(["host", "hostname", "address", "ip"]) else { return nil }
            var entry = Entry(name: text(["name", "label", "alias"]) ?? address, address: address)
            if let port = text(["port"]).flatMap(Int.init), (1...65535).contains(port) { entry.port = port }
            entry.user = text(["user", "username"]) ?? ""
            entry.type = text(["type", "kind"]).flatMap { HostType(word: $0)?.rawValue } ?? "ssh"
            entry.group = text(["group", "folder", "path"]) ?? ""
            entry.jump = text(["jump", "proxyjump"])
            return entry
        }
    }

    /// `Host` blocks of an OpenSSH config. One entry per alias without a
    /// wildcard; `Host *` gives User / Port to entries that set none; `Match`
    /// blocks and `Include` are not followed. `skipped` = wildcard aliases.
    /// File order counts, as in ssh: see `defaults` below. A quote never
    /// closed refuses the whole file, as ssh does — skipping the line moved
    /// its options into the wrong block (Fable round 16); `invalidLine` says
    /// where (1-based).
    static func entries(fromSSHConfig text: String) -> (entries: [Entry], skipped: Int, invalidLine: Int?) {
        struct Block { var aliases: [String]; var options: [String: String] = [:] }
        var blocks: [Block] = []
        var inMatch = false
        for (number, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            guard let read = scan(String(line)) else { continue }
            if read.unclosed { return ([], 0, number + 1) }
            let (key, value) = (read.key, read.value)
            // A keyword with no value — bare, or only quotes — ssh refuses the
            // whole file for ("no argument", "empty argument"); so do we, so
            // nothing after it lands in the block above (Fable rounds 17, 18).
            if value.isEmpty { return ([], 0, number + 1) }
            switch key {
            case "host":
                inMatch = false
                blocks.append(Block(aliases: value.split(whereSeparator: \.isWhitespace).map(String.init)))
            case "match":
                inMatch = true
            default:
                // First value wins, as in ssh; options before any Host apply to all.
                guard !inMatch else { continue }
                if blocks.isEmpty { blocks.append(Block(aliases: ["*"])) }
                if blocks[blocks.count - 1].options[key] == nil { blocks[blocks.count - 1].options[key] = value }
            }
        }
        // ssh's rule: the first value obtained wins, in file order. A `Host *`
        // ABOVE a block beats it; one below only fills what it left unset
        // (Fable round 10).
        func defaults(_ range: some Sequence<Block>) -> [String: String] {
            range.filter { $0.aliases.contains("*") }.reduce(into: [String: String]()) { all, block in
                for (k, v) in block.options where all[k] == nil { all[k] = v }
            }
        }
        var out: [Entry] = []
        var skipped = 0
        for (index, block) in blocks.enumerated() {
            let before = defaults(blocks[..<index]), after = defaults(blocks[(index + 1)...])
            for alias in block.aliases {
                if alias.contains(where: { "*?!".contains($0) }) {
                    if alias != "*" { skipped += 1 }
                    continue
                }
                func option(_ k: String) -> String? { before[k] ?? block.options[k] ?? after[k] }
                var entry = Entry(name: alias, address: option("hostname") ?? alias)
                if let port = option("port").flatMap(Int.init), (1...65535).contains(port) { entry.port = port }
                entry.user = option("user") ?? ""
                // One hop only: the first of a chain.
                if let jump = option("proxyjump"), jump.lowercased() != "none" {
                    entry.jump = jump.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
                }
                out.append(entry)
            }
        }
        return (out, skipped, nil)
    }

    /// A line ssh refuses for its quotes: one opened and never closed.
    static func hasUnclosedQuote(_ line: String) -> Bool { scan(line)?.unclosed ?? false }

    /// "Keyword value" or "Keyword=value", comments and blank lines nil.
    /// A "#" after whitespace starts a comment — outside quotes only, so a
    /// value this file wrote as "john #1" reads back whole (Fable round 11);
    /// quotes come off and \" inside them is a quote, as in ssh.
    static func keyword(_ line: String) -> (key: String, value: String)? {
        // A quote never closed: ssh refuses the line ("invalid quotes"); so do we (Fable round 15).
        guard let read = scan(line), !read.unclosed, !read.value.isEmpty else { return nil }
        return (read.key, read.value)
    }

    /// The keyword, its value as ssh reads it, and whether a quote was left open.
    private static func scan(_ line: String) -> (key: String, value: String, unclosed: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        // A keyword alone ("Host"): no value — `entries` refuses a bare Host as ssh does (Fable round 17).
        guard let gap = trimmed.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else { return (trimmed.lowercased(), "", false) }
        let key = trimmed[..<gap].lowercased()
        let raw = trimmed[gap...].drop { $0.isWhitespace || $0 == "=" }
        var value = ""
        // The quote that opened, ' or " — ssh takes both (Fable round 14).
        var quote: Character?
        var inQuotes: Bool { quote != nil }
        var previous: Character = " "
        var chars = raw.makeIterator()
        while let c = chars.next() {
            if c == "\\", inQuotes, let next = chars.next() {
                // \" \' and \\ are one character inside quotes (Fable rounds
                // 12, 13); any other backslash stays, as in ssh.
                if next != "\"" && next != "'" && next != "\\" { value.append("\\") }
                value.append(next)
                previous = next
                continue
            }
            if c == "\"" || c == "'" {
                if quote == nil { quote = c; previous = c; continue }
                if quote == c { quote = nil; previous = c; continue }
            }
            if c == "#", !inQuotes, previous.isWhitespace { break }
            value.append(c)
            previous = c
        }
        return (key, value.trimmingCharacters(in: .whitespaces), inQuotes)
    }

    /// Rows for Add Hosts, through the parser a paste uses: a tab-separated
    /// table with its header (Name, Host / IP, Group, Type).
    static func sheetText(_ entries: [Entry]) -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["Name\tHost / IP\tGroup\tType"]
        for e in entries { lines.append([e.name, target(e), e.group, e.type].map(cell).joined(separator: "\t")) }
        return lines.joined(separator: "\n")
    }

    /// The Add Hosts examples (6.1 (9)): kept here, beside the reader they
    /// must satisfy, so the harness proves each one imports.
    enum Examples {
        /// A type's badge, the words a Type cell may hold, and a sample row (Name, Host / IP).
        static let types: [(type: HostType, words: String, name: String, host: String)] = [
            (.ssh, "ssh", "Core-SW1", "admin@10.0.0.1"),
            (.server, "server, srv", "Web-01", "root@192.0.2.10:2222"),
            (.docker, "docker, container", "App-Container", "deploy@192.0.2.20"),
            (.cloud, "cloud", "AWS-Bastion", "ec2-user@203.0.113.5"),
            (.jump, "jump, bastion", "Bastion-01", "ops@192.0.2.1"),
            (.telnet, "telnet", "Old-Switch", "10.0.0.50:23"),
            (.web, "web, https", "FortiGate GUI", "https://192.168.1.99"),
        ]

        static let csv = """
        Name,Host / IP,Type,Group
        Core-SW1,admin@10.0.0.1,ssh,Head Office
        Old-Switch,10.0.0.50:23,telnet,Lab
        FortiGate GUI,https://192.168.1.99,web,
        """

        static let json = """
        [
          {"name": "Core-SW1", "host": "10.0.0.1", "user": "admin",
           "type": "ssh", "group": "Head Office/Building A"},
          {"name": "Bastion-01", "host": "192.0.2.1", "port": 22, "type": "jump"}
        ]
        """

        static let sshConfig = """
        Host core-sw1
            HostName 10.0.0.1
            User admin
        Host web-01
            HostName 192.0.2.10
            Port 2222
            ProxyJump bastion-01
        """

    }
}
