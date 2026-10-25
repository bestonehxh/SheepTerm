import Foundation

/// Address-bar suggestions from Google (SheepTerm 5.0 (53), shared): what typed text may be
/// sent, and the fetch.
///
/// What is never sent (the owner's rule, 2026-10-25: "เฉพาะที่เป็น private IP ไม่ต้องส่ง"): text that
/// contains a private or local address anywhere — RFC 1918, CGNAT 100.64/10, loopback, link-local, 0/8,
/// IPv6 ULA / link-local / loopback, in any form WebKit itself would read as one (octal, hex, short or
/// integer IPv4 — `0xC0A80101`, `3232235777`, `192.168.257` — full-width digits, `。` dots), still being
/// typed (`192.16`), or wrapped in punctuation (`(10.0.0.1)`, `10.0.0.1\admin`); a LAN name (`localhost`,
/// `.local`, `.lan`, `.internal`, `.localdomain`, `.corp`, `.home`, `.intranet`, `.private`, `.home.arpa`);
/// any `host:port`; a name or address the app already knows as a saved / recent host (`known`). Also
/// never: a scheme or a user@ part (a pasted link can carry a token), `file:` / `about:`, more than 200
/// characters. Words and public names may go. The fetch carries no cookies.
public nonisolated enum WebSuggest {
    public static func mayAsk(_ typed: String, known: [String] = []) -> Bool {
        // What WebKit would read: compatibility forms folded (full-width digits), every dot a dot.
        var text = typed.precomposedStringWithCompatibilityMapping
        for dot in ["\u{3002}", "\u{FF0E}", "\u{FF61}"] { text = text.replacingOccurrences(of: dot, with: ".") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200 else { return false }
        let lower = text.lowercased()
        if lower.contains("://") || lower.contains("@") || lower.hasPrefix("file:") || lower.hasPrefix("about:") { return false }
        // A saved or recent host's name or address (customer device names stay home).
        for name in known {
            let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 3, lower.contains(name) { return false }
        }
        // Every run of characters a host could be made of: anything else (space, NBSP, brackets of a
        // phrase, commas, slashes, backslashes) separates them.
        let hostChars = Set("abcdefghijklmnopqrstuvwxyz0123456789.:-[]%_")
        let tokens = lower.split { !hostChars.contains($0) }.map(String.init)
        for raw in tokens {
            if isPrivateAddress(raw) { return false }   // "::1" whole, before its colons are trimmed
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ":-_"))
            guard !token.isEmpty else { continue }
            if isPrivateAddress(token) { return false }
            // "host:port" (one colon, digits after it) — a device, whatever its name.
            let colons = token.filter { $0 == ":" }.count
            if colons == 1, let port = token.split(separator: ":").last, !port.isEmpty, port.allSatisfy(\.isNumber),
               token.first != "[" { return false }
            // "http:10.0.0.1", "10.0.0.1:8080:" — each piece on its own (an IPv6 literal was checked whole).
            if colons >= 1, token.split(separator: ":").contains(where: { isPrivateAddress(String($0)) }) { return false }
        }
        return true
    }

    /// A private / local IP literal (any form `inet_aton` / `inet_pton` accept) or LAN-only name, with an
    /// optional port and path ("10.0.0.1", "192.168.1.1:8443/login", "[fd00::1]:443", "fe80::1%en0",
    /// "sw1.local", "0xC0A80101"), or the start of a private IPv4 address being typed ("192.16").
    public static func isPrivateAddress(_ word: String) -> Bool {
        var host = word.lowercased()
        // Path, query, fragment.
        if let cut = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == "\\" }) { host = String(host[..<cut]) }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1 {
            host = String(host.split(separator: ":", omittingEmptySubsequences: false)[0])   // host:port
        }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        let typed = host    // "192." as typed, for the partly-typed check below
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        for suffix in [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".localdomain", ".corp", ".home",
                       ".intranet", ".private"] where host.hasSuffix(suffix) { return true }
        // Private if ANY reading of it is: WebKit's (`inet_aton`: "010" is octal 8), the one a person means
        // (decimal, leading zeros dropped), or one still being typed.
        if let v4 = ipv4(host), isPrivateV4(v4) { return true }
        let decimal = host.split(separator: ".", omittingEmptySubsequences: false).map { part -> String in
            let trimmed = part.drop { $0 == "0" }
            return part.allSatisfy(\.isNumber) && !part.isEmpty ? (trimmed.isEmpty ? "0" : String(trimmed)) : String(part)
        }.joined(separator: ".")
        if decimal != host, decimal.contains("."), let v4 = ipv4(decimal), isPrivateV4(v4) { return true }
        if host.contains(":"), let v6 = ipv6(host) { return isPrivateV6(v6) }
        return partlyTypedPrivate(typed)
    }

    /// "192.16", "172.", "10.0", "100.6": a private IPv4 address the user is still typing (the next
    /// keystroke would make it one) — the last part may be the start of the octet that decides.
    private static func partlyTypedPrivate(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...4).contains(parts.count), parts.allSatisfy({ $0.isEmpty || ($0.count <= 3 && $0.allSatisfy(\.isNumber)) }),
              let first = Int(parts[0]) else { return false }
        if first == 10 || first == 127 || first == 0 { return true }
        let ranges: [Int: ClosedRange<Int>] = [192: 168...168, 172: 16...31, 169: 254...254, 100: 64...127]
        guard let range = ranges[first] else { return false }
        let second = parts[1]
        if second.isEmpty { return true }
        // A finished second part (more parts follow) must be in the range; the last one may be a prefix of it.
        if parts.count > 2 { return Int(second).map(range.contains) ?? false }
        return range.contains { String($0).hasPrefix(second) }
    }

    /// The 4 bytes WebKit would connect to for `host`, read as `inet_aton` does (octal "0300", hex
    /// "0xc0", short "192.168.257", a whole integer "3232235777"); nil when it is not an IPv4 literal.
    /// A bare small number ("10", "2024") is a word, not an address.
    private static func ipv4(_ host: String) -> [UInt8]? {
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x") }) else { return nil }
        if !host.contains(".") {
            if host.hasPrefix("0x") { /* hex integer */ } else if let value = UInt64(host), value >= 16_777_216 { /* integer */ } else { return nil }
        }
        var addr = in_addr()
        guard inet_aton(host, &addr) == 1 else { return nil }
        let value = UInt32(bigEndian: addr.s_addr)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func isPrivateV4(_ b: [UInt8]) -> Bool {
        b[0] == 10 || b[0] == 127 || b[0] == 0
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
            || (b[0] == 100 && (64...127).contains(b[1]))
    }

    /// The 16 bytes of an IPv6 literal (`inet_pton` rules), nil when it is not one.
    private static func ipv6(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func isPrivateV6(_ b: [UInt8]) -> Bool {
        if b.allSatisfy({ $0 == 0 }) { return true }                                  // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }           // ::1
        if b[0] & 0xfe == 0xfc { return true }                                        // fc00::/7 ULA
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                        // fe80::/10 link-local
        // ::ffff:a.b.c.d — the IPv4 rules.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivateV4(Array(b[12..<16])) }
        return false
    }

    /// No cookies, no cache: nothing ties the typing to the user's Google account.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    /// Google's suggestions for `query` (nil task = not asked: `mayAsk` said no). The completion
    /// runs on the main queue with the words, or [] on any failure.
    @discardableResult
    public static func fetch(_ query: String, known: [String] = [], language: String? = Locale.preferredLanguages.first,
                             completion: @escaping @MainActor @Sendable ([String]) -> Void) -> URLSessionDataTask? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mayAsk(text, known: known), var components = URLComponents(string: "https://suggestqueries.google.com/complete/search") else { return nil }
        components.queryItems = [.init(name: "client", value: "firefox"), .init(name: "q", value: text),
                                 .init(name: "hl", value: language ?? "en")]
        guard let url = components.url else { return nil }
        let task = session.dataTask(with: url) { data, _, _ in
            let words = parse(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(words) } }
        }
        task.resume()
        return task
    }

    /// `["query", ["a", "b"], …]` → ["a", "b"] (at most 10, each at most 200 characters).
    public static func parse(_ data: Data?) -> [String] {
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [Any], list.count > 1,
              let words = list[1] as? [String] else { return [] }
        return Array(words.filter { !$0.isEmpty && $0.count <= 200 }.prefix(10))
    }
}
