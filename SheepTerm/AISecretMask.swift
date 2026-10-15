import Foundation

/// AI panel: takes the secrets out of device output BEFORE it can be sent to a
/// model. Foundation only and in `sharedSources`, so the Windows build masks
/// with exactly the same rules.
///
/// Only the VALUE is replaced (`<removed>`); the keyword stays, so the model
/// still sees `enable secret 9 <removed>` and understands the config. The
/// rules are token based on purpose — no regex — and every keyword list is a
/// `static let` here, tested in `Tests/tests/AIMaskTests.swift` (both the
/// lines that must be masked and the ones that must stay as they are, e.g.
/// `password-policy enable` or a `show run | include password` echo).
public nonisolated enum AISecretMask {
    public static let replacement = "<removed>"

    public struct Result: Equatable, Sendable {
        public var text: String
        /// Values replaced (a PEM block counts once).
        public var removed: Int
    }

    /// Keywords whose next value (after optional qualifiers such as `7`,
    /// `ENC`, `cipher`, `plaintext`) is a secret wherever they appear.
    static let strongKeywords: Set<String> = [
        "password", "passwd", "secret", "key-string", "pre-shared-key", "psksecret", "wpa-passphrase",
        "passphrase", "ciphertext", "plaintext", "authentication-key", "encrypted-password", "auth-key",
        "shared-key", "wpa-psk", "psk", "auth-pwd", "priv-pwd", "api-key", "sae-password", "ppk-secret",
        "password-encrypt", "auth-pass", "priv-pass", "md5-key", "ascii-text", "password:", "secret:",
        "passphrase:", "irreversible-cipher", "message-digest-key", "authkey", "enckey",
        "plain-text-password-value",
    ]

    /// Tokens skipped between a keyword and its value: encryption types and
    /// value-format words from the vendors' syntax.
    static let qualifiers: Set<String> = [
        "0", "5", "6", "7", "8", "9", "enc", "simple", "plain", "plaintext", "ciphertext", "cipher",
        "irreversible-cipher", "ascii-text", "hexadecimal", "ascii", "hex", "encrypted", "unencrypted",
        "hidden", ":", "=", "set-key",
    ]

    /// A keyword followed by one of these is a feature or an English sentence,
    /// not a credential (`password encryption aes`, `password policy`,
    /// `key chain`, "password for admin changed").
    static let nonValueWords: Set<String> = [
        "encryption", "policy", "complexity", "complexity-check", "aging", "history", "min-length",
        "minimum-length", "length", "expire", "expiration", "expired", "change", "changed", "recovery",
        "required", "lockout", "retry", "control", "restriction", "alert", "prompt", "hash", "is", "for",
        "was", "must", "has", "will", "the", "of", "not", "incorrect", "invalid", "failed", "accepted",
        "reset", "management", "manager", "chain", "generate", "zeroize", "mypubkey", "pubkey-chain",
        "config-key", "import", "export", "storage", "decrypt", "encrypt", "|", ">", "include", "exclude",
        "begin", "section", "authentication", "mode", "strength", "security", "algorithm", "rsa", "ec",
        "address", "hostname", "local", "remote", "and", "or", "to", "on", "off", "enable", "disable",
        "add", "set", "print", "remove", "edit", "find", "export",
    ]

    static let punctuation = CharacterSet(charactersIn: ",;:.")

    /// Plain English that follows a number (`5 remaining`, `3 attempts`).
    static let countWords: Set<String> = [
        "remaining", "left", "attempts", "attempt", "tries", "times", "days", "day", "hours", "minutes",
        "seconds", "characters", "chars", "more", "ago", "since", "until", "of",
    ]

    /// Lines (or the block a line is indented under) starting with one of
    /// these make a bare `key <value>` a credential: TACACS / RADIUS / IKE.
    static let keyContexts: Set<String> = [
        "tacacs-server", "radius-server", "tacacs", "radius", "hwtacacs-server", "crypto", "isakmp",
    ]

    /// `name=value` pairs (MikroTik, URLs) whose value is a secret.
    static let keyValueNames: Set<String> = [
        "password", "passwd", "secret", "pre-shared-key", "wpa-pre-shared-key", "wpa2-pre-shared-key",
        "passphrase", "authentication-key", "auth-key", "psk", "private-key-passphrase", "api-key", "token",
    ]

    /// Algorithm / format words between `auth` / `priv` and the key in an
    /// SNMPv3 user line.
    static let snmpAlgorithms: Set<String> = [
        "md5", "sha", "sha1", "sha-1", "sha224", "sha-224", "sha256", "sha-256", "sha384", "sha-384",
        "sha512", "sha-512", "des", "3des", "aes", "aes128", "aes192", "aes256", "aes-128", "aes-192",
        "aes-256", "128", "192", "256", "auth-pass", "priv-pass", "plaintext", "ciphertext", "encrypted",
        "0", "7", "8",
    ]

    /// Keywords written `<keyword> <key id> <algorithm> [qualifier] <value>`
    /// (`ntp authentication-key 1 md5 X 7`, `ip ospf message-digest-key 1
    /// md5 7 X`, Aruba `… 10 sha1 ciphertext X`): the id and the algorithm
    /// are skipped. A bare `authentication-key X` (OSPF) is unchanged.
    static let keyIDKeywords: Set<String> = ["authentication-key", "message-digest-key"]

    static let digestAlgorithms: Set<String> = [
        "md5", "sha", "sha1", "sha-1", "sha224", "sha256", "sha384", "sha512", "hmac-sha1", "hmac-sha256",
        "hmac-md5", "aes-cmac", "cmac-aes",
    ]

    /// First-redundancy-protocol lines whose `authentication [text] <value>`
    /// is the group's key (`standby 1 authentication X`, `vrrp 1
    /// authentication text X`). `… authentication md5 key-string X` is
    /// caught by `key-string`; `md5 key-chain NAME` names a chain, not a key.
    static let fhrpContexts: Set<String> = ["standby", "vrrp", "glbp"]

    /// Words that make a `name=value` / `"name": value` / `name_with_underscores:`
    /// name a credential, after `_` → `-` (`DB_PASSWORD`, `wpa_passphrase`,
    /// `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `api_key`).
    static let secretNameWords = ["password", "passwd", "secret", "token", "passphrase", "api-key", "apikey",
                                  "private-key"]

    static func normalisedName(_ raw: Substring) -> String {
        var name = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        while let f = name.first, f == "\"" || f == "'" || f == "-" { name.removeFirst() }
        while let l = name.last, l == "\"" || l == "'" { name.removeLast() }
        return name
    }

    /// The name of a `name=value` pair or a quoted JSON / YAML key.
    static func isSecretName(_ name: String) -> Bool {
        keyValueNames.contains(name) || secretNameWords.contains { name.contains($0) }
    }

    /// An unquoted `name:` (YAML, `show` output): snake_case names follow
    /// `isSecretName`; anything else must END in one of the words, so
    /// `token-bucket:` or `password-policy:` stay as they are.
    static func isSecretLabel(_ raw: Substring) -> Bool {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        let name = normalisedName(raw)
        if raw.contains("_") { return isSecretName(name) }
        return secretNameWords.contains { name == $0 || name.hasSuffix("-" + $0) }
    }

    /// `"name":` / `'name':` keys inside one token: the name's range and
    /// where its value starts (endIndex = the value is the next token).
    static func quotedKeys(in text: Substring) -> [(Range<Substring.Index>, Substring.Index)] {
        var out: [(Range<Substring.Index>, Substring.Index)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            guard c == "\"" || c == "'" else { i = text.index(after: i); continue }
            let bodyStart = text.index(after: i)
            guard let close = text[bodyStart...].firstIndex(of: c) else { break }
            let after = text.index(after: close)
            if after < text.endIndex, text[after] == ":", close > bodyStart {
                out.append((bodyStart..<close, text.index(after: after)))
                i = text.index(after: after)
            } else {
                i = after
            }
        }
        return out
    }

    /// A value inside a token: a quoted string's body, or up to `,` / `}` / `]`.
    static func quotedOrBareValue(in text: Substring, from start: Substring.Index) -> Range<String.Index>? {
        guard start < text.endIndex else { return nil }
        let q = text[start]
        if q == "\"" || q == "'" {
            let body = text.index(after: start)
            let close = text[body...].firstIndex(of: q) ?? text.endIndex
            return body < close ? body..<close : nil
        }
        let stop = text[start...].firstIndex { $0 == "," || $0 == "}" || $0 == "]" } ?? text.endIndex
        return start < stop ? start..<stop : nil
    }

    /// `scheme://user:PASSWORD@host…` inside a token: the password's range.
    static func urlPasswordRange(in text: Substring) -> Range<String.Index>? {
        guard let scheme = text.range(of: "://") else { return nil }
        let rest = text[scheme.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }
        let userinfo = authority[..<at]
        // The colon may be percent-encoded: `admin%3Apass@host`.
        let colonEnd: Substring.Index
        if let colon = userinfo.firstIndex(of: ":") {
            colonEnd = authority.index(after: colon)
        } else if let enc = userinfo.range(of: "%3a", options: .caseInsensitive) {
            colonEnd = enc.upperBound
        } else {
            return nil
        }
        return colonEnd < at ? colonEnd..<at : nil
    }

    static let authSchemes: Set<String> = ["bearer", "basic", "digest", "token", "negotiate", "ntlm"]

    /// Prefixes of crypt-style hashes and vendor-encrypted strings that are
    /// masked wherever they stand: md5/sha crypt, Cisco type 8/9, Junos $9$,
    /// Huawei `$1a$`…`$1d$` and `%^%#…`.
    static let hashPrefixes = ["$1$", "$2a$", "$2b$", "$2y$", "$5$", "$6$", "$8$", "$9$", "$y$",
                               "$1a$", "$1b$", "$1c$", "$1d$", "%^%#", "%@%@", "%$%$"]

    /// Minimum length of the session's own password before it is replaced
    /// wherever it appears (shorter strings would shred ordinary output).
    static let minimumKnownSecretLength = 4

    public static func mask(_ text: String, knownSecrets: [String] = []) -> Result {
        var removed = 0
        var out: [String] = []
        var inPEM = false
        var blockHeader: [String] = []
        let lines = text.components(separatedBy: "\n")
        out.reserveCapacity(lines.count)
        for line in lines {
            if inPEM {
                if isPEMEnd(line) {
                    inPEM = false
                    out.append(replacement)
                    out.append(line)
                }
                continue
            }
            if isPEMBegin(line) {
                inPEM = true
                removed += 1
                out.append(line)
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            let (masked, count, tokens) = maskLine(line, blockHeader: indented ? blockHeader : [])
            if !indented, !tokens.isEmpty { blockHeader = tokens }
            removed += count
            out.append(masked)
        }
        // A key block the output cut off: nothing after BEGIN is kept.
        if inPEM { out.append(replacement) }
        var result = out.joined(separator: "\n")
        for secret in Set(knownSecrets) where secret.count >= minimumKnownSecretLength && secret != replacement {
            let parts = result.components(separatedBy: secret)
            if parts.count > 1 {
                removed += parts.count - 1
                result = parts.joined(separator: replacement)
            }
        }
        return Result(text: result, removed: removed)
    }

    static func isPEMBegin(_ line: String) -> Bool {
        line.contains("-----BEGIN") && line.contains("PRIVATE KEY")
    }

    static func isPEMEnd(_ line: String) -> Bool {
        line.contains("-----END") && line.contains("PRIVATE KEY")
    }

    static func isHash(_ token: Substring) -> Bool {
        var t = token
        if t.first == "\"" || t.first == "'" { t = t.dropFirst() }
        return hashPrefixes.contains { t.hasPrefix($0) && t.count > $0.count + 2 }
    }

    private struct Token {
        var range: Range<String.Index>
        var text: Substring
        var lower: String
    }

    /// One line: masked text, values removed, and its lower-cased tokens (the
    /// block header for the indented lines that follow).
    private static func maskLine(_ line: String, blockHeader: [String]) -> (String, Int, [String]) {
        var tokens: [Token] = []
        var i = line.startIndex
        while i < line.endIndex {
            while i < line.endIndex, line[i] == " " || line[i] == "\t" || line[i] == "\r" { i = line.index(after: i) }
            guard i < line.endIndex else { break }
            let start = i
            while i < line.endIndex, line[i] != " ", line[i] != "\t", line[i] != "\r" { i = line.index(after: i) }
            let text = line[start..<i]
            tokens.append(Token(range: start..<i, text: text, lower: text.lowercased()))
        }
        let lowers = tokens.map(\.lower)
        guard !tokens.isEmpty else { return (line, 0, lowers) }

        // Replacement ranges into `line` (non-overlapping), and which tokens they cover.
        var ranges: [Range<String.Index>] = []
        var used = Set<Int>()

        /// Mask from token `j` (optionally from an offset inside it) through a
        /// closing quote. Trailing `;` / `,` stay.
        func maskValue(_ j: Int, from start: String.Index? = nil) {
            guard j < tokens.count, !used.contains(j) else { return }
            var first = start ?? tokens[j].range.lowerBound
            var last = j
            var lastEnd = tokens[j].range.upperBound
            let opening = line[first...].first
            if opening == "\"" || opening == "'" {
                let q = opening!
                first = line.index(after: first)
                // Find the closing quote in this or a later token.
                let bodyInFirst = line[first..<tokens[j].range.upperBound]
                if let close = bodyInFirst.firstIndex(of: q) {
                    lastEnd = close
                } else {
                    var k = j + 1
                    var found: String.Index?
                    while k < tokens.count {
                        if let close = tokens[k].text.firstIndex(of: q) { found = close; break }
                        k += 1
                    }
                    if let found {
                        last = k
                        lastEnd = found
                    } else {
                        last = tokens.count - 1
                        lastEnd = tokens[last].range.upperBound
                    }
                }
            } else {
                while lastEnd > first, let c = line[..<lastEnd].last, c == ";" || c == "," {
                    lastEnd = line.index(before: lastEnd)
                }
            }
            guard first < lastEnd else { return }
            for k in j...last { used.insert(k) }
            ranges.append(first..<lastEnd)
        }

        /// The value after keyword `i`: skip qualifiers; nothing when the
        /// line ends or a non-value word follows.
        func valueIndex(after i: Int, skipping skip: Set<String> = qualifiers) -> Int? {
            var j = i + 1
            while j < tokens.count, skip.contains(tokens[j].lower) { j += 1 }
            guard j < tokens.count else { return nil }
            let word = tokens[j].lower.trimmingCharacters(in: punctuation)
            if nonValueWords.contains(word) || word.hasPrefix("|") { return nil }
            // `token: 5 remaining`: a count and its unit, not a credential.
            if j > i + 1, tokens[j - 1].lower.allSatisfy(\.isNumber), countWords.contains(word) { return nil }
            return j
        }

        let snmpLine = lowers.contains { $0.hasPrefix("snmp") }
        let keyContext = lowers.contains { keyContexts.contains($0) } || blockHeader.first.map { keyContexts.contains($0) } == true

        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            if used.contains(index) { continue }
            let token = tokens[index]
            let lower = token.lower

            if isHash(token.text) { maskValue(index); continue }

            // URL user info: `https://admin:SECRET@10.0.0.1/` — the password part only.
            if let range = urlPasswordRange(in: token.text) {
                ranges.append(range)
                used.insert(index)
                continue
            }

            if lower == "authorization:" {
                var j = index + 1
                if j < tokens.count, authSchemes.contains(tokens[j].lower) { j += 1 }
                if j < tokens.count {
                    ranges.append(tokens[j].range.lowerBound..<tokens[tokens.count - 1].range.upperBound)
                    for k in j..<tokens.count { used.insert(k) }
                }
                break
            }
            if lower == "bearer", index + 1 < tokens.count, tokens[index + 1].text.count >= 8 {
                maskValue(index + 1); continue
            }

            if let eq = token.text.firstIndex(of: "="), eq != token.text.startIndex {
                let name = normalisedName(token.text[..<eq])
                let valueStart = token.text.index(after: eq)
                if isSecretName(name) {
                    if valueStart < token.text.endIndex {
                        maskValue(index, from: valueStart)
                    } else if index + 1 < tokens.count {
                        maskValue(index + 1)          // `password= SECRET`
                    }
                    continue
                }
            }
            // `DB_PASSWORD =SECRET` / `DB_PASSWORD = SECRET` / `secret_key= x`:
            // a credential name, then a token starting with `=`.
            if index + 1 < tokens.count, tokens[index + 1].text.first == "=", !token.text.contains("="),
               isSecretLabel(token.text) || strongKeywords.contains(lower) {
                let next = tokens[index + 1]
                if next.text.count > 1 {
                    maskValue(index + 1, from: next.text.index(after: next.text.startIndex))
                } else if index + 2 < tokens.count {
                    maskValue(index + 2)
                }
                continue
            }
            // `password:hunter2` / `password:"x"`: no space after the colon.
            if let colon = token.text.firstIndex(of: ":"), colon != token.text.startIndex,
               token.text.index(after: colon) < token.text.endIndex, !token.text.contains("://"),
               isSecretLabel(token.text[..<colon]) {
                maskValue(index, from: token.text.index(after: colon))
                continue
            }
            // `"password" :"x"`: a quoted credential name, then a token starting with the colon.
            if index + 1 < tokens.count, tokens[index + 1].text.first == ":", tokens[index + 1].text.count > 1,
               let q = token.text.first, q == "\"" || q == "'", token.text.count > 2, token.text.last == q,
               isSecretName(normalisedName(token.text)) {
                let next = tokens[index + 1]
                maskValue(index + 1, from: next.text.index(after: next.text.startIndex))
                continue
            }
            // `{ "password" : "SECRET" }`: a quoted credential name, then a lone colon.
            if index + 2 < tokens.count, tokens[index + 1].text == ":",
               let q = token.text.first, q == "\"" || q == "'", token.text.count > 2, token.text.last == q,
               isSecretName(normalisedName(token.text)) {
                maskValue(index + 2)
                continue
            }

            // JSON / YAML quoted keys: `"password": "x"`, `'secret': 'y'`,
            // compact `{"user":"a","client_secret":"x"}` (several per token).
            if token.text.contains("\":") || token.text.contains("':") {
                var keyed = false
                var valueInNext = false
                for (keyRange, valueStart) in quotedKeys(in: token.text) where isSecretName(normalisedName(token.text[keyRange])) {
                    keyed = true
                    if valueStart == token.text.endIndex {
                        valueInNext = true
                    } else if let r = quotedOrBareValue(in: token.text, from: valueStart) {
                        ranges.append(r)
                    }
                }
                if keyed {
                    used.insert(index)
                    if valueInNext, index + 1 < tokens.count, tokens[index + 1].text.first != "{", tokens[index + 1].text.first != "[" {
                        maskValue(index + 1)
                    }
                }
                if !quotedKeys(in: token.text).isEmpty { continue }
            }

            if strongKeywords.contains(lower) {
                var after = index
                // `enable password level 15 7 X`: the privilege level is not the value.
                if (lower == "password" || lower == "secret"), index + 2 < tokens.count, tokens[index + 1].lower == "level",
                   tokens[index + 2].text.allSatisfy(\.isNumber) {
                    after = index + 2
                }
                // `ntp authentication-key 1 md5 X 7`: skip the key id and the algorithm.
                if keyIDKeywords.contains(lower), index + 2 < tokens.count,
                   tokens[index + 1].text.allSatisfy(\.isNumber), digestAlgorithms.contains(tokens[index + 2].lower) {
                    after = index + 2
                }
                // IKEv2 keyring: `pre-shared-key local X` / `remote X`.
                if lower == "pre-shared-key", index + 1 < tokens.count, ["local", "remote"].contains(tokens[index + 1].lower) {
                    after = index + 1
                }
                if let j = valueIndex(after: after) { maskValue(j) }
                continue
            }
            if lower == "authentication", lowers.first.map({ fhrpContexts.contains($0) }) == true {
                var after = index
                if index + 1 < tokens.count, tokens[index + 1].lower == "text" { after = index + 1 }
                if index + 1 < tokens.count, tokens[index + 1].lower == "md5" { continue }
                if let j = valueIndex(after: after) { maskValue(j) }
                continue
            }
            // Unquoted label: `DB_PASSWORD: x`, `client-secret: y`, `Session token: z`.
            if token.text.count > 1, token.text.last == ":", isSecretLabel(token.text.dropLast()) {
                if let j = valueIndex(after: index) { maskValue(j) }
                continue
            }
            if lower == "key" {
                // `key 7 <v>` / `key 0 <v>` anywhere; a bare `key <v>` only
                // in a TACACS / RADIUS / IKE line or block.
                if index + 2 < tokens.count, ["0", "6", "7"].contains(tokens[index + 1].lower),
                   let j = valueIndex(after: index) {
                    maskValue(j)
                } else if keyContext, let j = valueIndex(after: index) {
                    maskValue(j)
                }
                continue
            }
            if lower == "community", snmpLine {
                let skip = qualifiers.union(["read", "write", "ro", "rw", "read-only", "read-write"])
                if let j = valueIndex(after: index, skipping: skip) { maskValue(j) }
                continue
            }
            // Huawei `usm-user … authentication-mode sha cipher X privacy-mode aes128 cipher Y`.
            if (lower == "authentication-mode" || lower == "privacy-mode"), snmpLine {
                if let j = valueIndex(after: index, skipping: snmpAlgorithms.union(qualifiers)) { maskValue(j) }
                continue
            }
            if (lower == "auth" || lower == "priv"), snmpLine {
                if let j = valueIndex(after: index, skipping: snmpAlgorithms) { maskValue(j) }
                continue
            }
        }

        guard !ranges.isEmpty else { return (line, 0, lowers) }
        var masked = ""
        var cursor = line.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            masked += line[cursor..<range.lowerBound]
            masked += replacement
            cursor = range.upperBound
        }
        masked += line[cursor...]
        return (masked, ranges.count, lowers)
    }
}
