import Foundation

// Per-host command history (5.0 (1)). Everything here is pure Foundation so
// `Tests/run.sh tests` compiles it: capture of the typed line from the
// screen, the secret filter, the capped list, the key a session files its
// history under, and history.json's load/save/quarantine. The store with its
// alerts is `CommandHistoryStore`, the hook is in `SessionTerminalHost`.

// MARK: - Secret filter

/// What must never reach history.json. A line is dropped when it carries
/// anything that looks like a credential, and a SCREEN ROW is dropped when
/// it looks like a credential prompt (the device does not echo a password,
/// so the row says "Password:" and nothing of what was typed).
nonisolated enum CommandHistoryFilter {
    /// Case-insensitive substrings. Substring, not word: `sha256`,
    /// `hmac-sha1`, `psk-key`, `snmp-server community` must all hit. The
    /// price is a few harmless commands (`… shaping`) that are not kept.
    static let secretKeywords: [String] = [
        "password", "secret", "community", "key-string", "pre-shared-key", "psk",
        "passphrase", "auth-key", "md5", "sha", "encrypted-password",
        "set passwd", "set psksecret", "snmp-server community", "radius-server key",
        // Beyond the required list: other spellings of the same thing.
        "passwd", "authentication-key", "token", "api-key", "apikey", "private-key", "credential",
        "shared-key", "authentication text", "sshpass", "curl -u", "--password", "mysql -p",
    ]

    /// `tacacs … key` / `radius … key` in any order of the words around it.
    static func isSensitive(_ line: String) -> Bool {
        let lower = line.lowercased()
        if secretKeywords.contains(where: { lower.contains($0) }) { return true }
        if (lower.contains("tacacs") || lower.contains("radius")) && lower.contains("key") { return true }
        // `crypto isakmp key MYKEY address …`, `crypto key …`: a key in a VPN/crypto line.
        if lower.contains("crypto") && lower.contains("key") { return true }
        // IOS-XE sub-modes take the secret on a line of its own: under
        // `tacacs server X` / `radius server X` it is just `key 0 MySecret`.
        // `key 1` (a key-chain id) and `key chain K1` are not secrets.
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.first == "key", words.count >= 2, words[1] != "chain",
           words.count > 2 || !words[1].allSatisfy(\.isNumber) { return true }
        return false
    }

    private static let promptRegex: NSRegularExpression = {
        // password / passphrase / secret / passcode / pin / enter … key /
        // username: / user name: / login: / login as:
        let pattern = #"password|passphrase|passcode|secret|\bpin\b|\benter\b.*\bkey\b|(user ?name|login)( as)? ?:"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// A screen row that is asking for a credential (or showing one).
    static func looksLikeCredentialPrompt(_ row: String) -> Bool {
        let range = NSRange(row.startIndex..., in: row)
        return promptRegex.firstMatch(in: row, options: [], range: range) != nil
    }
}

// MARK: - Capture

nonisolated enum CommandHistoryCapture {
    /// A longer line is not a command somebody will recall.
    static let maxLength = 300
    /// A prompt longer than this is output text, not a prompt.
    static let maxPromptLength = 80

    /// The logical line the cursor is on: rows joined across soft wraps
    /// (a long command wraps at the window's width). Continuation rows are
    /// passed untrimmed by the caller — a space at the wrap point is part of
    /// the command — and only the last row loses its right padding.
    static func logicalLine(rows: [(text: String, wrapped: Bool)], cursorRow: Int) -> String? {
        guard rows.indices.contains(cursorRow) else { return nil }
        var first = cursorRow
        var steps = 0
        while rows[first].wrapped, first > 0, steps < 12 { first -= 1; steps += 1 }
        var last = cursorRow
        steps = 0
        while last + 1 < rows.count, rows[last + 1].wrapped, steps < 12 { last += 1; steps += 1 }
        var out = ""
        for index in first...last { out += rows[index].text }
        while let end = out.last, end == " " || end == "\t" || end == "\u{0}" { out.removeLast() }
        return out
    }

    /// The command on a screen line, with the prompt cut off: everything up
    /// to and including the FIRST prompt terminator (`#` `>` `$` `]`) and a
    /// following space. The first, not the last: a command may itself hold
    /// `>` or `$` (`| include a>b`), a prompt is before it. nil when the
    /// line is not recognisably "prompt + command" — skipped, never guessed.
    static func command(fromRow row: String) -> String? {
        let line = row.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if CommandHistoryFilter.looksLikeCredentialPrompt(line) { return nil }
        // The whole row too: the prompt carries the mode the command is
        // typed in (`R1(config-server-tacacs)# key 0 X` → tacacs + key).
        if CommandHistoryFilter.isSensitive(line) { return nil }

        let chars = Array(line)
        let terminators: Set<Character> = ["#", ">", "$", "]"]
        guard let t = chars.firstIndex(where: { terminators.contains($0) }) else { return nil }
        // A prompt has a name in front of its terminator, and is short.
        guard t >= 1, t <= maxPromptLength else { return nil }
        // A syslog line `<189>Oct 9 …` printed over the console is not a prompt.
        if chars[0] == "<", t >= 2, chars[1..<t].allSatisfy({ $0.isNumber || $0 == "<" }) { return nil }
        var end = t + 1
        // `[user@host ~]$ ` and `[HUAWEI]#`: the bracket and the terminator
        // after it are both the prompt.
        if chars[t] == "]", end < chars.count, ["#", "$", ">"].contains(chars[end]) { end += 1 }
        let command = String(chars[end...]).trimmingCharacters(in: .whitespaces)
        return accepted(command)
    }

    /// The final gate for a candidate line (also the one `CommandHistory`
    /// applies to anything it is handed, and to a file it loads).
    static func accepted(_ command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        // Any control character: it is not text somebody typed at a prompt.
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value < 0xA0) }) {
            return nil
        }
        if CommandHistoryFilter.isSensitive(text) { return nil }
        // An answer to a question (`[Y/N]: y` → ": y", `[startup-config]?`
        // → "?") is not a command: a command starts with a word or a path.
        guard let first = text.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) || "/.~_".unicodeScalars.contains(first) else { return nil }
        return text
    }
}

/// Decides whether the screen can be trusted at the moment Return is
/// pressed. The device echoes what is typed, so a Return that follows a key
/// whose echo has not arrived yet would read a half-typed line — and a
/// password (no echo at all) leaves the screen untouched. Both look the same
/// from here: the terminal's change counter did not move since the last key.
nonisolated struct HistoryEchoGate {
    private var pending = false
    private var stamp: UInt64 = 0

    /// A key (or pasted text) that is not Return went out.
    mutating func typed(counter: UInt64) {
        pending = true
        stamp = counter
    }

    /// Return was pressed: may the screen be read? `true` for a Return that
    /// follows output (the echo) or follows nothing typed at all.
    mutating func returned(counter: UInt64) -> Bool {
        defer { pending = false }
        return !pending || counter != stamp
    }
}

// MARK: - The list

nonisolated struct CommandHistoryData: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// Most recent first.
        var commands: [String]
        var updated: Date
    }
    var version = 1
    var hosts: [String: Entry] = [:]
}

nonisolated enum CommandHistory {
    static let maxPerHost = 500
    /// Keys kept; the least recently used go first. Bounds the file against
    /// hosts that were deleted long ago.
    static let maxHosts = 100
    /// A file bigger than this is not ours.
    static let maxFileBytes = 16 * 1024 * 1024

    /// Adds `command` for `key`. Returns false when nothing changed (refused
    /// by the filter, or the same as the most recent line).
    @discardableResult
    static func add(_ command: String, for key: String, to data: inout CommandHistoryData, now: Date = Date()) -> Bool {
        guard !key.isEmpty, let line = CommandHistoryCapture.accepted(command) else { return false }
        var entry = data.hosts[key] ?? .init(commands: [], updated: now)
        if entry.commands.first == line { return false }
        entry.commands.insert(line, at: 0)
        if entry.commands.count > maxPerHost { entry.commands.removeLast(entry.commands.count - maxPerHost) }
        entry.updated = now
        data.hosts[key] = entry
        trimHosts(&data)
        return true
    }

    static func commands(for key: String, in data: CommandHistoryData) -> [String] {
        data.hosts[key]?.commands ?? []
    }

    @discardableResult
    static func clear(_ key: String, in data: inout CommandHistoryData) -> Bool {
        data.hosts.removeValue(forKey: key) != nil
    }

    private static func trimHosts(_ data: inout CommandHistoryData) {
        guard data.hosts.count > maxHosts else { return }
        let oldest = data.hosts.sorted { $0.value.updated < $1.value.updated }.prefix(data.hosts.count - maxHosts)
        for (key, _) in oldest { data.hosts.removeValue(forKey: key) }
    }

    /// What a loaded file is allowed to contain: each line goes through the
    /// same gate as a live one (a hand-edited file must not smuggle a secret
    /// back in), lists are capped, consecutive duplicates collapse.
    static func normalised(_ raw: CommandHistoryData) -> CommandHistoryData {
        var out = CommandHistoryData()
        for (key, entry) in raw.hosts where !key.isEmpty && key.count <= 300 {
            var lines: [String] = []
            for command in entry.commands {
                guard let line = CommandHistoryCapture.accepted(command), lines.last != line else { continue }
                lines.append(line)
                if lines.count == maxPerHost { break }
            }
            if !lines.isEmpty { out.hosts[key] = .init(commands: lines, updated: entry.updated) }
        }
        trimHosts(&out)
        return out
    }

    // MARK: key

    /// The key a session files its history under. A saved host by id (the
    /// name and address may be edited; the history stays); a quick connect by
    /// what it connects to; a serial console by its device path. A local
    /// shell has none — it is not a device.
    static func key(kind: ConnectionKind, savedID: UUID?, username: String, address: String, port: Int) -> String? {
        switch kind {
        case .local:
            return nil
        case .ssh, .serial:
            if let savedID { return "host:" + savedID.uuidString }
            let target = address.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            if kind == .serial { return "serial:" + target }
            let user = username.trimmingCharacters(in: .whitespaces)
            return "ssh:" + (user.isEmpty ? "" : user + "@") + target.lowercased() + ":" + String(port)
        }
    }
}

// MARK: - File

/// history.json on disk: the rules recents.json follows, minus what does not
/// apply. A file that cannot be read is left alone and writes stop until the
/// user clears history; a file that reads but does not decode is moved aside
/// as `.corrupt-<stamp>` (so the original is safe and writing may go on —
/// history is rebuilt by use, unlike hosts); every first write of a run
/// leaves a `.bak`.
nonisolated enum CommandHistoryFile {
    struct Loaded {
        var data: CommandHistoryData
        var warning: String?
        /// Writes must not happen until the user's next explicit change.
        var suppressWrites: Bool
    }

    static func load(from url: URL, stamp: () -> String = Self.corruptStamp) -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return Loaded(data: .init(), warning: nil, suppressWrites: false) }
        let raw: Data
        do {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > CommandHistory.maxFileBytes { throw CocoaError(.fileReadTooLarge) }
            raw = try Data(contentsOf: url)
        } catch {
            if (error as? CocoaError)?.code == .fileReadTooLarge {
                return quarantine(url, reason: "was larger than \(CommandHistory.maxFileBytes / 1_048_576) MB", stamp: stamp)
            }
            let warning = "\(url.lastPathComponent) could not be read (\(error.localizedDescription)). "
                + "Command history starts empty and the file will not be overwritten until you clear history."
            return Loaded(data: .init(), warning: warning, suppressWrites: true)
        }
        guard let decoded = try? JSONDecoder.history.decode(CommandHistoryData.self, from: raw) else {
            return quarantine(url, reason: "was unreadable", stamp: stamp)
        }
        return Loaded(data: CommandHistory.normalised(decoded), warning: nil, suppressWrites: false)
    }

    private static func quarantine(_ url: URL, reason: String, stamp: () -> String) -> Loaded {
        let aside = url.appendingPathExtension("corrupt-\(stamp())")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            let warning = "\(url.lastPathComponent) \(reason) and could not be moved aside (\(error.localizedDescription)). "
                + "Command history starts empty and the file will not be overwritten until you clear history."
            return Loaded(data: .init(), warning: warning, suppressWrites: true)
        }
        return Loaded(data: .init(),
                      warning: "history.json \(reason); the original was preserved as \(aside.lastPathComponent) and command history starts empty.",
                      suppressWrites: false)
    }

    /// Atomic write. With `backup`, the file on disk is first copied to `.bak`.
    static func save(_ data: CommandHistoryData, to url: URL, backup: Bool) throws {
        let encoded = try JSONEncoder.history.encode(data)
        let fm = FileManager.default
        if backup, fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            let staging = url.appendingPathExtension("bak.tmp")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: url, to: staging)
            _ = try fm.replaceItemAt(bak, withItemAt: staging)
        }
        try encoded.write(to: url, options: .atomic)
    }

    static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

nonisolated private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
