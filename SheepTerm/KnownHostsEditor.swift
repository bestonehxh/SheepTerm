import CryptoKit
import Foundation

/// The pure half of File → Known Hosts…: read ~/.ssh/known_hosts into rows,
/// search them (hashed names included) and cut lines out of the file without
/// touching any other byte. No AppKit, no SheepSSH — the `tests` harness
/// compiles this file on its own. The locked write lives next to
/// `SSHWorker.pinFirstUse` (`SSHWorker.removeKnownHosts`), which shares its
/// locks.
///
/// Format details follow SheepSSH's `KnownHosts` (the parser the trust
/// decision uses): lines split on LF with a trailing CR ignored, leading and
/// trailing blanks trimmed, `#` comments, an optional `@revoked` /
/// `@cert-authority` marker, then host field, key type, base64 key. Unlike
/// `KnownHosts`, a line whose key type SheepSSH does not know is still an
/// entry here — the editor exists to let such lines be removed too.
nonisolated enum KnownHostsEditor {
    enum Marker: String, Sendable, Equatable, Hashable {
        case certAuthority = "@cert-authority"
        case revoked = "@revoked"
    }

    /// What identifies an entry across a re-read of the file: the line's
    /// content, never its position (lines may be added or removed above it
    /// while the sheet is open).
    struct Identity: Sendable, Hashable {
        let marker: Marker?
        let hostsField: String
        let keyType: String
        let keyBase64: String
    }

    struct Entry: Sendable, Equatable, Identifiable {
        /// 0-based index of the line in the file (line number − 1).
        let lineIndex: Int
        let marker: Marker?
        /// The host field exactly as written.
        let hostsField: String
        /// The comma-separated host patterns; empty for a hashed entry.
        let hosts: [String]
        /// `|1|salt|hash`: the name is not recoverable, only matchable.
        let hashed: Bool
        let keyType: String
        let keyBase64: String
        /// "SHA256:" + unpadded base64 of SHA-256(key blob) — what
        /// `ssh-keygen -lf` prints.
        let fingerprint: String

        var id: Int { lineIndex }
        var identity: Identity { Identity(marker: marker, hostsField: hostsField, keyType: keyType, keyBase64: keyBase64) }
    }

    // MARK: Parse

    static func parse(_ text: String) -> [Entry] { parse(bytes: Array(text.utf8)) }

    static func parse(bytes: [UInt8]) -> [Entry] {
        var entries: [Entry] = []
        for (index, range) in lineRanges(bytes).enumerated() {
            if let entry = entry(line: String(decoding: bytes[range.content], as: UTF8.self), index: index) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// One line (no terminator) → an entry, or nil for a comment, a blank
    /// line or anything that does not parse.
    static func entry(line raw: String, index: Int) -> Entry? {
        let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
        if line.isEmpty || line.hasPrefix("#") { return nil }
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var marker: Marker?
        if let first = fields.first, first.hasPrefix("@") {
            guard let m = Marker(rawValue: first) else { return nil }
            marker = m
            fields.removeFirst()
        }
        guard fields.count >= 3,
              let blob = Data(base64Encoded: fields[2]), !blob.isEmpty,
              embeddedKeyType(Array(blob)) == fields[1] else { return nil }
        let hostsField = fields[0]
        let hashed = hostsField.hasPrefix("|1|")
        return Entry(lineIndex: index, marker: marker, hostsField: hostsField,
                     hosts: hashed ? [] : hostsField.split(separator: ",").map(String.init),
                     hashed: hashed, keyType: fields[1], keyBase64: fields[2],
                     fingerprint: fingerprint(blob: Array(blob)))
    }

    /// The type name a key blob starts with (uint32 length + string) — the
    /// line's key type must agree with it, as SheepSSH's key parser demands.
    private static func embeddedKeyType(_ blob: [UInt8]) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        guard length > 0, length <= blob.count - 4 else { return nil }
        return String(bytes: blob[4..<(4 + length)], encoding: .utf8)
    }

    static func fingerprint(blob: [UInt8]) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    // MARK: Search

    /// Does `entry` belong in the list filtered by `query`? Plain names match
    /// by case-insensitive substring; a hashed name can only be matched
    /// exactly, so `query` is tried as written, as "[query]:22", and — for a
    /// "host:port" or "[host]:port" query — as "[host]:port" (and plain
    /// "host" when the port is 22, which is how OpenSSH writes port 22). A
    /// query starting "SHA256:" also matches the fingerprint.
    static func matches(_ entry: Entry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        if q.hasPrefix("sha256:"), entry.fingerprint.lowercased().hasPrefix(q) { return true }
        let names = lookupNames(q)
        if entry.hashed {
            return names.contains { hashedMatches(entry.hostsField, name: $0) }
        }
        // What was typed, as a substring; or a name OpenSSH would look up
        // for it, as the whole pattern (so "host:2222" finds "[host]:2222"
        // but "host:22" does not), wildcards included ("*.lab").
        return entry.hosts.contains { host in
            let h = host.lowercased()
            if h.contains(q) { return true }
            if h.hasPrefix("!") { return false }
            return names.contains { wildcardMatch(h, $0) }
        }
    }

    /// OpenSSH match_pattern (`*` any run, `?` one character) — the same as
    /// SheepSSH's `KnownHosts.wildcardMatch`.
    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(text.unicodeScalars)
        var pi = 0, ti = 0, starP = -1, starT = 0
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

    /// The exact names a hashed line could have been written for, given what
    /// was typed.
    static func lookupNames(_ q: String) -> [String] {
        func split(_ s: String) -> (host: String, port: Int)? {
            if s.hasPrefix("["), let close = s.range(of: "]:") {
                let host = String(s[s.index(after: s.startIndex)..<close.lowerBound])
                guard !host.isEmpty, let port = Int(s[close.upperBound...]) else { return nil }
                return (host, port)
            }
            // Exactly one colon: an IPv6 literal has several and no port.
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]) else { return nil }
            return (String(parts[0]), port)
        }
        if let hp = split(q) {
            return hp.port == 22 ? ["[\(hp.host)]:22", hp.host] : ["[\(hp.host)]:\(hp.port)"]
        }
        return [q, "[\(q)]:22"]
    }

    /// OpenSSH's "|1|base64(salt)|base64(HMAC-SHA1(salt, name))".
    static func hashedMatches(_ field: String, name: String) -> Bool {
        let parts = field.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "1",
              let salt = Data(base64Encoded: String(parts[2])),
              let hash = Data(base64Encoded: String(parts[3])), hash.count == 20 else { return false }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
        return Data(mac) == hash
    }

    // MARK: Remove

    /// Where each line sits in the file: `whole` includes its LF, `content`
    /// does not (a CR before the LF stays in `content`; the parser trims it).
    /// A file ending in LF has no empty "line" after it.
    static func lineRanges(_ bytes: [UInt8]) -> [(whole: Range<Int>, content: Range<Int>)] {
        var ranges: [(whole: Range<Int>, content: Range<Int>)] = []
        var start = 0
        for i in bytes.indices where bytes[i] == 0x0A {
            ranges.append((start..<(i + 1), start..<i))
            start = i + 1
        }
        if start < bytes.count { ranges.append((start..<bytes.count, start..<bytes.count)) }
        return ranges
    }

    /// `bytes` without the lines at `lineIndices` (each with its own line
    /// terminator); every other byte — comments, order, CRLF, a missing
    /// final newline — is kept exactly. Unknown indices are ignored.
    static func removing(lineIndices: Set<Int>, from bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for (index, range) in lineRanges(bytes).enumerated() where !lineIndices.contains(index) {
            out.append(contentsOf: bytes[range.whole])
        }
        return out
    }

    static func removing(lineIndices: Set<Int>, from text: String) -> String {
        String(decoding: removing(lineIndices: lineIndices, from: Array(text.utf8)), as: UTF8.self)
    }

    /// The lines of `bytes` (as it is NOW) that hold one of `identities`.
    /// Two identical lines are both picked: leaving one would keep the pin
    /// the user asked to remove.
    static func lineIndices(holding identities: Set<Identity>, in bytes: [UInt8]) -> Set<Int> {
        Set(parse(bytes: bytes).filter { identities.contains($0.identity) }.map(\.lineIndex))
    }
}
