// ~/.ssh/known_hosts: lookup and the line we append on first connection.
//
// Matching follows OpenSSH sshd(8) "SSH_KNOWN_HOSTS FILE FORMAT":
//  - the name looked up is "host" on port 22 and "[host]:port" otherwise,
//    lowercased;
//  - the host field is a comma list of patterns with `*` and `?` wildcards; a
//    pattern starting with `!` that matches VETOES the whole line;
//  - "|1|<base64 salt>|<base64 HMAC-SHA1(salt, name)>" is a hashed entry;
//  - "@revoked" marks a key that must never be accepted for those hosts;
//    "@cert-authority" lines are CA keys, which SheepSSH does not use, so
//    they are skipped.
// Lines that do not parse are skipped (as OpenSSH does) and counted.
//
// The outcome mirrors what SheepTerm's SSHWorker already acts on, which
// were libssh's states: ok / changed / other type / not found — plus revoked.
import Foundation

public struct KnownHosts: Sendable {
    public enum Marker: Sendable, Equatable { case none, revoked, certAuthority }

    public struct Entry: Sendable, Equatable {
        public let marker: Marker
        /// The host field exactly as written.
        public let hostField: String
        public let key: SSHPublicKey
        /// 1-based line number in the file, for messages.
        public let line: Int

        public static func == (a: Entry, b: Entry) -> Bool {
            a.marker == b.marker && a.hostField == b.hostField && a.key.blob == b.key.blob && a.line == b.line
        }
    }

    public enum Result: Sendable, Equatable {
        /// A line for this host holds exactly this key.
        case ok(line: Int)
        /// Lines for this host hold a different key of the SAME type.
        case changed(lines: [Int])
        /// The host is known, but only with keys of other types (the
        /// downgrade-by-dropping-the-pinned-type case).
        case otherType(knownTypes: [String], lines: [Int])
        /// Nothing for this host.
        case notFound
        /// This key is marked @revoked for this host.
        case revoked(line: Int)
    }

    public let entries: [Entry]
    /// Non-empty, non-comment lines that could not be parsed.
    public let skippedLines: Int

    public init(text: String) {
        var entries: [Entry] = []
        var skipped = 0
        var lineNumber = 0
        // Not split(separator: "\n"): in Swift "\r\n" is ONE Character, so a
        // file with Windows line endings never split at all and every pinned
        // key was silently skipped — any key then read as "first connection".
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var marker = Marker.none
            if let first = fields.first, first.hasPrefix("@") {
                switch first {
                case "@revoked": marker = .revoked
                case "@cert-authority": marker = .certAuthority
                default: skipped += 1; continue
                }
                fields.removeFirst()
            }
            guard fields.count >= 3,
                  let key = try? SSHPublicKey(openSSHLine: fields[1] + " " + fields[2]) else {
                skipped += 1
                continue
            }
            entries.append(Entry(marker: marker, hostField: fields[0], key: key, line: lineNumber))
        }
        self.entries = entries
        self.skippedLines = skipped
    }

    /// The name OpenSSH looks up (and writes) for a host and port.
    public static func lookupName(host: String, port: Int) -> String {
        let h = host.lowercased()
        return port == 22 ? h : "[\(h)]:\(port)"
    }

    public func lookup(host: String, port: Int, key: SSHPublicKey) -> Result {
        let name = Self.lookupName(host: host, port: port)
        var sameTypeLines: [Int] = []
        var otherTypes: [String] = []
        var otherTypeLines: [Int] = []
        var okLine: Int?
        for entry in entries where entry.marker != .certAuthority && Self.hostFieldMatches(entry.hostField, name: name) {
            if entry.marker == .revoked {
                if entry.key.blob == key.blob { return .revoked(line: entry.line) }
                continue
            }
            if entry.key.keyType == key.keyType {
                if entry.key.blob == key.blob {
                    okLine = okLine ?? entry.line
                } else {
                    sameTypeLines.append(entry.line)
                }
            } else {
                otherTypeLines.append(entry.line)
                if !otherTypes.contains(entry.key.keyType) { otherTypes.append(entry.key.keyType) }
            }
        }
        // A matching key wins over a stale line of the same type elsewhere in
        // the file (OpenSSH behaves the same: any matching line is enough).
        if let okLine { return .ok(line: okLine) }
        if !sameTypeLines.isEmpty { return .changed(lines: sameTypeLines) }
        if !otherTypes.isEmpty { return .otherType(knownTypes: otherTypes, lines: otherTypeLines) }
        return .notFound
    }

    /// Key types pinned for this host (lookup order, no duplicates, revoked
    /// and CA lines excluded). libssh put these first in its host-key offer
    /// (ssh_client_select_hostkeys), so a device pinned as ECDSA or RSA keeps
    /// presenting that key instead of an ed25519 one that would read as a
    /// type change.
    public func pinnedKeyTypes(host: String, port: Int) -> [String] {
        let name = Self.lookupName(host: host, port: port)
        var types: [String] = []
        for entry in entries where entry.marker == .none && Self.hostFieldMatches(entry.hostField, name: name) {
            if !types.contains(entry.key.keyType) { types.append(entry.key.keyType) }
        }
        return types
    }

    /// The line to append when a first-seen key is accepted (unhashed, as
    /// libssh wrote it), newline included.
    public static func line(host: String, port: Int, key: SSHPublicKey) -> String {
        "\(lookupName(host: host, port: port)) \(key.keyType) \(key.base64)\n"
    }

    // MARK: Matching

    static func hostFieldMatches(_ field: String, name: String) -> Bool {
        if field.hasPrefix("|1|") { return hashedMatches(field, name: name) }
        var positive = false
        for pattern in field.split(separator: ",") {
            if pattern.hasPrefix("!") {
                if wildcardMatch(pattern.dropFirst().lowercased(), name) { return false }
            } else if wildcardMatch(pattern.lowercased(), name) {
                positive = true
            }
        }
        return positive
    }

    static func hashedMatches(_ field: String, name: String) -> Bool {
        let parts = field.split(separator: "|", omittingEmptySubsequences: false)
        // "", "1", salt, hash
        guard parts.count == 4,
              let salt = Data(base64Encoded: String(parts[2])),
              let hash = Data(base64Encoded: String(parts[3])),
              hash.count == 20 else { return false }
        let computed = SSHHash.sha1.hmac(key: Array(salt), message: Array(name.utf8))
        return constantTimeEqual(computed, Array(hash))
    }

    /// OpenSSH match_pattern: `*` = any run (possibly empty), `?` = one
    /// character. Case is folded by the callers.
    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(text.unicodeScalars)
        var pi = 0, ti = 0
        var starP = -1, starT = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                starP = pi; starT = ti; pi += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if starP >= 0 {
                pi = starP + 1; starT += 1; ti = starT
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
