import Foundation

// Web tabs (ConnectionKind.web): the pure rules — URL normalisation, origin
// matching for Fill Login, the certificate-trust decision and the Fill Login
// script. No AppKit/WebKit here: Tests/run.sh compiles this file (SRC) and
// `Tests/tests/WebTabTests.swift` holds every rule to its cases. The app side
// is `WebTabController.swift` / `WebHostSheet.swift`. ARCHITECTURE.md "Web tabs".

/// What a web host's address field may hold, and how it is stored.
nonisolated enum WebAddress {
    enum Problem: Error, Equatable, Sendable {
        case empty, whitespace, scheme, invalid
        /// `https://user:pass@host` — the password belongs in a credential.
        case passwordInURL

        /// The short line under the field.
        var message: String {
            switch self {
            case .empty: return "Enter a URL"
            case .whitespace: return "URL must not contain spaces"
            case .scheme: return "Only http:// and https:// are supported"
            case .invalid: return "Not a valid URL"
            case .passwordInURL: return "Put the password in a credential, not the URL"
            }
        }
    }

    static let schemes: Set<String> = ["http", "https"]

    /// True when `text` starts with `http://` or `https://` (any case) — what
    /// the connect box / Quick Search / Add Hosts read as "a web target".
    static func hasWebScheme(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// The URL to store for what the user typed: no scheme → `https://`;
    /// only http/https; a host is required; an explicit port must be 1–65535.
    /// The scheme and host are lower-cased; path, query and fragment are kept.
    static func normalize(_ text: String) -> Result<String, Problem> {
        normalizeDetailed(text).map(\.url)
    }

    /// `normalize` plus what was taken OUT of the URL: user info never stays
    /// in a stored address (hosts.json is plaintext; the sidebar and recents
    /// show the address). `user` = the name that was in it (the form keeps it
    /// as the host's username when that field is empty); `hadPassword` = a
    /// password was in it (the forms refuse it: `problem` says so).
    static func normalizeDetailed(_ text: String) -> Result<(url: String, user: String?, hadPassword: Bool), Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return .failure(.whitespace) }
        var candidate = trimmed
        if let range = trimmed.range(of: "://") {
            let scheme = trimmed[..<range.lowerBound].lowercased()
            guard schemes.contains(scheme) else { return .failure(.scheme) }
        } else {
            // `javascript:…`, `file:/…`, `data:…` — a scheme without "//":
            // a colon before the first "/" whose tail is not a port number.
            // (`host:8080` and a bracketed IPv6 literal are not schemes.)
            let head = trimmed.prefix { $0 != "/" }
            if !head.hasPrefix("["), let colon = head.firstIndex(of: ":") {
                let tail = head[head.index(after: colon)...]
                // A bare IPv6 literal needs its brackets: `https://[fe80::1]`.
                if tail.contains(":") { return .failure(.invalid) }
                if tail.isEmpty || !tail.allSatisfy(\.isNumber) { return .failure(.scheme) }
            }
            candidate = "https://" + trimmed
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              let host = components.host, !host.isEmpty else { return .failure(.invalid) }
        if let port = components.port, !(1...65_535).contains(port) { return .failure(.invalid) }
        components.scheme = scheme
        components.host = host.lowercased()
        let user = components.user.flatMap { $0.isEmpty ? nil : $0 }
        let hadPassword = !(components.password ?? "").isEmpty
        components.user = nil
        components.password = nil
        guard let url = components.url?.absoluteString else { return .failure(.invalid) }
        return .success((url, user, hadPassword))
    }

    /// The same question as `normalize`, for a field: nil = fine. A password
    /// inside the URL is refused here (the form's short error).
    static func problem(_ text: String) -> Problem? {
        switch normalizeDetailed(text) {
        case .failure(let problem): return problem
        case .success(let result): return result.hadPassword ? .passwordInURL : nil
        }
    }

    /// Defensive: an address from a file, a share, a backup or Sync without
    /// any `user:pass@`. Unparseable text is returned as it was.
    static func strippingUserInfo(_ address: String) -> String {
        guard address.contains("@") else { return address }
        if var components = URLComponents(string: address), components.host != nil,
           components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
            if let url = components.url?.absoluteString { return url }
        }
        // Not parseable as scheme://user@host (`https:/u:pw@h/`, odd
        // slashes): cut the user-info segment textually — a stored address
        // must never keep a password just because the URL is malformed.
        return textuallyStrippingUserInfo(address)
    }

    /// `scheme:` + any slashes, then the authority up to `/ ? #`: everything
    /// in it up to the last `@` goes. A segment with whitespace is not user
    /// info (prose, not a URL) and is left alone.
    static func textuallyStrippingUserInfo(_ text: String) -> String {
        var start = text.startIndex
        if let colon = text.firstIndex(of: ":"), colon > text.startIndex,
           text[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }),
           schemes.contains(text[..<colon].lowercased()) || text[colon...].hasPrefix("://") {
            start = text.index(after: colon)
            while start < text.endIndex, text[start] == "/" || text[start] == "\\" { start = text.index(after: start) }
        }
        let end = text[start...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? text.endIndex
        guard let at = text[start..<end].lastIndex(of: "@"),
              !text[start..<at].contains(where: \.isWhitespace) else { return text }
        return String(text[..<start]) + String(text[text.index(after: at)...])
    }

    /// Whether a URL may be loaded in a web tab at all (the URL bar, a
    /// navigation the page starts): http/https only.
    static func isLoadable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }

    /// The port a web host is stored with — the URL's effective port. Not
    /// used to connect (WebKit reads the URL); kept so `connectionKey` and
    /// the Windows port see a real number.
    static func effectivePort(of urlString: String) -> Int {
        origin(of: urlString)?.port ?? 443
    }

    /// The URL without its scheme and a lone trailing "/" — the sidebar's
    /// detail line ("10.0.0.1:8443/admin").
    static func shortLabel(_ urlString: String) -> String {
        var text = displayURL(strippingUserInfo(urlString))
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("/"), text.filter({ $0 == "/" }).count == 1 { text.removeLast() }
        return text
    }

    /// The host part to show (sidebar detail, card subtitle, names): an IDN
    /// host in its own letters (`ไทย.th`, not `xn--o3cw4h.th`) — see
    /// `displayHostLabels`.
    static func displayHost(of urlString: String) -> String {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { return urlString }
        return displayHostLabels(components) ?? urlString
    }

    /// What the web tab's URL field does with what was typed (2026-10-15:
    /// "like a browser" — the field is also a Google search box).
    enum Typed: Equatable, Sendable {
        case empty
        /// Load this (already normalised) URL.
        case url(String)
        /// http(s):// typed but not a usable URL: say why.
        case invalid(Problem)
        /// Search for the text.
        case search(String)
    }

    static let searchBase = "https://www.google.com/search?q="

    /// The rule: a typed http(s):// scheme → that URL (or why not); otherwise
    /// something host-shaped — a dot in the host, `localhost`, a bracketed
    /// IPv6, with an optional :port and path, no spaces (`10.1.1.1`,
    /// `fw.lab:8443/login`, `ไทย.th`) → https:// + it, as before; ANYTHING else
    /// (spaces, one word without a dot, a question, another scheme) → a search.
    static func classifyTyped(_ text: String) -> Typed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if hasWebScheme(trimmed) {
            switch normalize(trimmed) {
            case .success(let url): return .url(url)
            case .failure(let problem): return .invalid(problem)
            }
        }
        // An "@" anywhere is user info, never a query: `admin:secret@10.0.0.1`
        // went to Google as a search — and into Recent — in plaintext (review
        // round 4). The part after the LAST "@" must be a host; a password in
        // it is refused (nothing loaded, nothing sent); a bare user is
        // dropped from the stored URL (`normalizeDetailed`).
        // Only an "@" in the AUTHORITY: one in the path/query/fragment (`10.0.0.1/a@b`, `?email=a@b.com`) is
        // an ordinary address (round 5).
        let authority = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") {
            guard !trimmed.contains(where: { $0.isWhitespace }),
                  looksLikeHost(String(trimmed[trimmed.index(after: at)...])) else { return .invalid(.invalid) }
            // With the scheme spelt out: `user:pw@…` would otherwise read as a scheme.
            switch normalizeDetailed("https://" + trimmed) {
            case .success(let result): return result.hadPassword ? .invalid(.passwordInURL) : .url(result.url)
            case .failure(let problem): return .invalid(problem)
            }
        }
        guard !trimmed.contains(where: { $0.isWhitespace }), looksLikeHost(trimmed),
              case .success(let url) = normalize(trimmed) else { return .search(searchURL(for: trimmed)) }
        return .url(url)
    }

    /// A search-results page (`searchURL`): never written to Recent — its
    /// address IS the query.
    static func isSearchResultsURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        return components.host?.lowercased() == "www.google.com" && components.path == "/search"
    }

    /// The authority part of a scheme-less entry is host-shaped.
    static func looksLikeHost(_ text: String) -> Bool {
        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if authority.hasPrefix("[") { return authority.contains("]") }
        var host = Substring(authority)
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
            host = host[..<colon]
        }
        guard !host.isEmpty, !host.contains("@"), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        return host.lowercased() == "localhost" || host.contains(".")
    }

    /// Google's search URL for `query` (every character but the unreserved
    /// ones percent-encoded, so `&`, `#`, `+` and Thai all survive).
    static func searchURL(for query: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return searchBase + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    /// A URL as a person reads it (the URL field, the sidebar): the host's
    /// IDN labels decoded, the path / query / fragment percent-DECODED, so a
    /// Thai page reads `ไทย.th/หน้า` and not `xn--…/%E0%B8%AB…`. Display only —
    /// what is stored and loaded stays the encoded form (`normalize`), and an
    /// edit made in the field goes back through `normalize`. Anything that
    /// does not parse is returned as it was.
    static func displayURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString), let scheme = components.scheme,
              components.host != nil, let host = displayHostLabels(components) else { return urlString }
        var text = scheme + "://"
        if let user = components.percentEncodedUser, !user.isEmpty { text += user + "@" }
        text += host.contains(":") ? "[\(host)]" : host
        if let port = components.port { text += ":\(port)" }
        func decoded(_ part: String) -> String { displayDecoded(part) }
        text += decoded(components.percentEncodedPath)
        if let query = components.percentEncodedQuery { text += "?" + decoded(query) }
        if let fragment = components.percentEncodedFragment { text += "#" + decoded(fragment) }
        return text
    }

    /// The host, each label decoded from punycode unless the decoded label
    /// MIXES ASCII letters with other letters (`аpple` with a Cyrillic а —
    /// the classic look-alike): such a label stays `xn--…`, as Safari does.
    /// IPv6 literals come back bare (no brackets).
    /// Percent-DECODES for display, except what would change the URL's
    /// meaning if the shown text were submitted again or would hide what it
    /// is: the delimiters `/ ? # @ % & = +`, space, C0/C1 controls and DEL,
    /// bidi controls (U+202A–202E, U+2066–2069, U+200E/F, U+061C) and
    /// zero-width / invisible characters (U+200B–200D, U+2060, U+FEFF) stay
    /// encoded. Invalid UTF-8 stays encoded.
    static func displayDecoded(_ part: String) -> String {
        func keepsEncoded(_ scalar: Unicode.Scalar) -> Bool {
            let v = scalar.value
            if "/?#@%&=+ ".unicodeScalars.contains(scalar) { return true }
            if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
            if [0x200E, 0x200F, 0x061C, 0x2060, 0xFEFF].contains(v) || (0x200B...0x200D).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return true }
            // Anything invisible, space-like or unassigned (soft hyphen, U+2028/9, NBSP, ideographic space,
            // variation selectors, tags, private use) stays encoded too (round 5).
            switch scalar.properties.generalCategory {
            case .format, .control, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse,
                 .unassigned, .surrogate, .nonspacingMark where v == 0x034F || (0xFE00...0xFE0F).contains(v):
                return true
            default:
                break
            }
            return (0xE0000...0xE007F).contains(v)
        }
        func hex(_ c: Character) -> UInt8? { c.isASCII ? c.hexDigitValue.map(UInt8.init) : nil }
        let chars = Array(part)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "%", i + 2 < chars.count, let hi = hex(chars[i + 1]), let lo = hex(chars[i + 2]) else {
                out.append(chars[i]); i += 1; continue
            }
            // A run of %XX bytes, decoded together (UTF-8 spans several).
            var bytes: [UInt8] = [hi << 4 | lo]
            var raw = String(chars[i...i + 2])
            var j = i + 3
            while j + 2 < chars.count, chars[j] == "%", let h = hex(chars[j + 1]), let l = hex(chars[j + 2]) {
                bytes.append(h << 4 | l); raw += String(chars[j...j + 2]); j += 3
            }
            if let text = String(bytes: bytes, encoding: .utf8) {
                for scalar in text.unicodeScalars {
                    if keepsEncoded(scalar) {
                        out += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            } else {
                out += raw
            }
            i = j
        }
        return out
    }

    /// Scripts with no Latin look-alikes: a label whose letters are all
    /// from these may be SHOWN decoded (`ไทย.th`, `例え.jp`, `한국.kr`).
    /// Cyrillic, Greek, Armenian, Cherokee, Latin-extended… are not here:
    /// an all-Cyrillic `аррӏе.com` (xn--80ak6aa92e) stays `xn--…`.
    static let decodableScriptRanges: [ClosedRange<UInt32>] = [
        0x0590...0x05FF,   // Hebrew
        0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,   // Arabic
        0x0900...0x0DFF,   // Devanagari … Sinhala (Indic)
        0x0E00...0x0E7F,   // Thai
        0x0E80...0x0EFF,   // Lao
        0x0F00...0x0FFF,   // Tibetan
        0x1000...0x109F,   // Myanmar
        0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,   // Hangul
        0x1200...0x137F,   // Ethiopic
        0x1780...0x17FF,   // Khmer
        0x2E80...0x2FDF, 0x3005...0x3007, 0x3040...0x30FF, 0x3100...0x312F, 0x31F0...0x31FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,   // CJK, kana, bopomofo
    ]

    /// One decoded label may be shown as it is: every character is an ASCII
    /// digit / hyphen, or from `decodableScriptRanges` — and it does not mix
    /// ASCII letters with non-ASCII ones.
    static func labelIsDisplayable(_ label: Substring) -> Bool {
        var asciiLetter = false, other = false
        for scalar in label.unicodeScalars {
            if scalar.isASCII {
                if scalar.properties.isAlphabetic { asciiLetter = true }
                continue
            }
            guard decodableScriptRanges.contains(where: { $0.contains(scalar.value) }) else { return false }
            other = true
        }
        return !(asciiLetter && other)
    }

    static func displayHostLabels(_ components: URLComponents) -> String? {
        guard var unicode = components.host?.lowercased(), !unicode.isEmpty else { return nil }
        if unicode.hasPrefix("["), unicode.hasSuffix("]") { unicode = String(unicode.dropFirst().dropLast()) }
        if unicode.contains(":") { return unicode }
        // The ASCII (punycode) form, label for label, from Foundation's IDNA.
        let ascii = (components.url?.host() ?? unicode).lowercased()
        let unicodeLabels = unicode.split(separator: ".", omittingEmptySubsequences: false)
        let asciiLabels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard unicodeLabels.count == asciiLabels.count else { return unicode }
        return zip(unicodeLabels, asciiLabels).map { decodedLabel, asciiLabel -> String in
            labelIsDisplayable(decodedLabel) ? String(decodedLabel) : String(asciiLabel)
        }.joined(separator: ".")
    }

    /// host:port as the network sees it — the ASCII (punycode) host, lower
    /// case, no brackets, no trailing dot, the default port filled in. What a
    /// TLS challenge's protection space names, so the two can be compared
    /// (`WebTrust.isMainTarget`, "is this the saved host's server").
    struct ServerKey: Hashable, Sendable {
        let host: String
        let port: Int

        init(host: String, port: Int) {
            var name = host.lowercased()
            if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
            if name.hasSuffix(".") { name.removeLast() }
            // A Unicode host is compared in its punycode form.
            if name.unicodeScalars.contains(where: { !$0.isASCII }),
               let ascii = URLComponents(string: "https://\(name)/")?.url?.host() {
                name = ascii.lowercased()
            }
            self.host = name
            self.port = port
        }
    }

    static func serverKey(of urlString: String) -> ServerKey? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme, let fallback = defaultPort(forScheme: scheme),
              let host = components.url?.host() ?? components.host, !host.isEmpty else { return nil }
        return ServerKey(host: host, port: components.port ?? fallback)
    }

    static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// scheme + host + port, the browser's same-origin key.
    struct Origin: Equatable, Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    /// The origin of a URL string: scheme and host lower-cased, IPv6
    /// brackets removed, the default port filled in (80/443). nil for
    /// anything that is not http/https with a host.
    static func origin(of urlString: String) -> Origin? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let fallback = defaultPort(forScheme: scheme),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        return Origin(scheme: scheme, host: host, port: components.port ?? fallback)
    }

    /// Fill Login's gate: the page on screen and the saved host are the same
    /// origin. Anything unparseable is NOT a match.
    static func sameOrigin(_ a: String, _ b: String) -> Bool {
        guard let left = origin(of: a), let right = origin(of: b) else { return false }
        return left == right
    }
}

/// The certificate decision for a web tab (5.0 web tabs). Inputs only, so
/// every branch is a harness case: did the system trust the chain, the leaf's
/// SHA-256, the hash stored on the saved host, and the hashes accepted
/// "Connect Once" in this tab.
nonisolated enum WebTrust {
    enum Decision: Equatable, Sendable {
        /// Load it. No card.
        case accept
        /// Not trusted and nothing stored: the card (Trust & Connect /
        /// Connect Once / Cancel).
        case ask
        /// Not trusted and a DIFFERENT certificate was trusted for this host
        /// before: the "certificate changed" card. Never accepted by itself.
        case askChanged
    }

    /// A "Connect Once" answer: for THIS server (host + port) and this
    /// certificate, not the certificate wherever it turns up.
    struct OnceKey: Hashable, Sendable {
        let host: String
        let port: Int
        let hash: String

        init(host: String, port: Int, hash: String) {
            var name = host.lowercased()
            if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
            if name.hasSuffix(".") { name.removeLast() }
            self.host = name
            self.port = port
            self.hash = hash.lowercased()
        }
    }

    /// Is a TLS challenge for the server the MAIN FRAME is going to (or is
    /// on)? Only that one may put up the certificate card. A subresource on
    /// another host — or the same host on another port — with an untrusted
    /// certificate is blocked silently, as browsers do (an ad host answered
    /// by a DNS blocker with a bogus certificate put the card up over
    /// google.com — the user, 2026-10-15). No main URL known = not main.
    static func isMainTarget(host: String, port: Int, mainURL: String?) -> Bool {
        guard let mainURL, let main = WebAddress.serverKey(of: mainURL) else { return false }
        return WebAddress.ServerKey(host: host, port: port) == main
    }

    /// The whole answer to one challenge: the system's verdict, then the
    /// main-frame scope, then `decide`.
    enum ChallengeAction: Equatable, Sendable {
        /// System-trusted: WebKit's default handling.
        case useDefault
        /// Untrusted, not the main frame's server: cancel, no card.
        case block
        case decided(Decision)
    }

    static func action(systemTrusted: Bool, isMainTarget: Bool, leafSHA256: String, stored: String?,
                       acceptedOnce: Set<OnceKey>, host: String, port: Int) -> ChallengeAction {
        if systemTrusted { return .useDefault }
        guard isMainTarget else { return .block }
        return .decided(decide(systemTrusted: false, leafSHA256: leafSHA256, stored: stored,
                               acceptedOnce: acceptedOnce, host: host, port: port))
    }

    static func decide(systemTrusted: Bool, leafSHA256: String, stored: String?,
                       acceptedOnce: Set<OnceKey>, host: String, port: Int) -> Decision {
        if systemTrusted { return .accept }
        let leaf = leafSHA256.lowercased()
        guard !leaf.isEmpty else { return .ask }
        let once = acceptedOnce.contains(OnceKey(host: host, port: port, hash: leaf))
        if let stored = stored?.lowercased(), !stored.isEmpty {
            if stored == leaf { return .accept }
            if once { return .accept }
            return .askChanged
        }
        if once { return .accept }
        return .ask
    }

    /// W6: servers the user refused during the CURRENT main-frame navigation
    /// (host:port). Further challenges for them in that navigation are
    /// cancelled without another card; a new main-frame navigation clears it.
    struct Refusals: Sendable {
        private var refused: Set<String> = []
        init() {}
        static func key(host: String, port: Int) -> String { OnceKey(host: host, port: port, hash: "").host + ":\(port)" }
        mutating func refuse(host: String, port: Int) { refused.insert(Self.key(host: host, port: port)) }
        func isRefused(host: String, port: Int) -> Bool { refused.contains(Self.key(host: host, port: port)) }
        mutating func newNavigation() { refused.removeAll() }
    }

    /// Lowercase hex, no separators: what `webTrustedCertSHA256` stores.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The card's two lines: upper-case byte pairs with colons, 16 bytes a
    /// line (how browsers and device CLIs print a certificate fingerprint).
    static func displayLines(_ hex: String) -> (String, String) {
        let upper = Array(hex.uppercased())
        var pairs: [String] = []
        var index = 0
        while index + 1 < upper.count {
            pairs.append(String(upper[index...index + 1]))
            index += 2
        }
        let first = pairs.prefix(16).joined(separator: ":")
        let second = pairs.dropFirst(16).joined(separator: ":")
        return (first, second)
    }
}

/// Fill Login (button only, never automatic, never submits).
nonisolated enum WebFillLogin {
    /// Run with `callAsyncJavaScript(_:arguments:in:contentWorld:)`; the
    /// values arrive as the JSON-encoded arguments `user` and `pass`, never
    /// spliced into the source. Finds the first VISIBLE password input and
    /// the last visible text/email input before it, sets their values with the
    /// native setter (so frameworks that track `value` see a change) and
    /// dispatches input + change. Returns "filled", "user-only" or "none".
    static let script = """
    const here = (() => {
      let h = location.hostname.toLowerCase();
      if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
      if (h.endsWith('.')) h = h.slice(0, -1);
      const p = location.port || (location.protocol === 'https:' ? '443' : location.protocol === 'http:' ? '80' : '');
      return { protocol: location.protocol, hostname: h, port: p };
    })();
    if (here.protocol !== expected.protocol || here.hostname !== expected.hostname || here.port !== expected.port) {
      return 'other-origin';
    }
    const visible = (el) => {
      if (el.disabled || el.readOnly) return false;
      const r = el.getBoundingClientRect();
      const s = window.getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
    };
    const inputs = Array.from(document.querySelectorAll('input'));
    const pwIndex = inputs.findIndex((el) => el.type === 'password' && visible(el));
    const isUserField = (el) => ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase()) && visible(el);
    let userField = null;
    const before = pwIndex >= 0 ? inputs.slice(0, pwIndex) : inputs;
    for (const el of before) { if (isUserField(el)) userField = el; }
    const setValue = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (userField && user.length > 0) setValue(userField, user);
    if (pwIndex >= 0 && pass.length > 0) { setValue(inputs[pwIndex], pass); return 'filled'; }
    if (userField && user.length > 0) return 'user-only';
    return 'none';
    """

    enum Refusal: Equatable, Sendable {
        case noLogin, otherOrigin, noPage, loading

        var message: String {
            switch self {
            case .noLogin: return "No saved login for this host"
            case .otherOrigin: return "Not filled — this page is not the saved host’s address"
            case .noPage: return "Nothing to fill yet"
            case .loading: return "Page is still loading"
            }
        }
    }

    /// The gate before anything is sent into a page: a login exists, a page
    /// is loaded and no navigation to ANOTHER origin is provisional (then
    /// `webView.url` is already the new address while the old document is
    /// still the one on screen — `isProvisional`), and that page is the saved
    /// host's origin. A committed page that keeps loading (long-poll, an
    /// iframe that never finishes) may be filled.
    /// The script then checks the document's own `location` against
    /// `expectedOrigin` — the last word, inside the page that would be filled.
    static func check(pageURL: String?, savedURL: String, username: String, hasPassword: Bool,
                      provisional: Bool = false) -> Refusal? {
        guard !username.isEmpty || hasPassword else { return .noLogin }
        guard let pageURL, !pageURL.isEmpty else { return .noPage }
        guard !provisional else { return .loading }
        guard WebAddress.sameOrigin(pageURL, savedURL) else { return .otherOrigin }
        return nil
    }

    /// True while the URL WebKit reports is not the committed document's
    /// origin (a navigation elsewhere has started but not committed). Same
    /// origin = not provisional for this purpose (pushState, a same-site
    /// link: the document is that origin either way).
    static func isProvisional(currentURL: String?, committedURL: String?) -> Bool {
        guard let currentURL, let committedURL else { return true }
        return !WebAddress.sameOrigin(currentURL, committedURL)
    }

    /// The `expected` argument of `script`: the saved URL's origin in
    /// `location`'s terms (protocol with its colon, bare host, port string).
    static func expectedOrigin(savedURL: String) -> [String: String]? {
        guard let origin = WebAddress.origin(of: savedURL) else { return nil }
        return ["protocol": origin.scheme + ":", "hostname": origin.host, "port": String(origin.port)]
    }

    /// The script's answer, as the tab reports it (nil = done).
    static func outcome(_ value: String?) -> Refusal? {
        switch value {
        case "filled", "user-only": return nil
        case "other-origin": return .otherOrigin
        default: return nil
        }
    }
}

/// When a web tab's Recent entry is renamed after its first page (the title
/// can land after didFinish): at most ONCE per tab, only while the page shown
/// is the same origin as the recent's address, only to a different name, and
/// never for a search-results page (review round 4: every title change after
/// the first load used to rename — and save — the recent).
nonisolated enum WebRecentRename {
    static func shouldRename(notedName: String?, alreadyRenamed: Bool, newName: String,
                             pageURL: String?, recentAddress: String) -> Bool {
        guard let notedName, !alreadyRenamed, newName != notedName, let pageURL,
              !WebAddress.isSearchResultsURL(recentAddress) else { return false }
        return WebAddress.sameOrigin(pageURL, recentAddress)
    }
}

extension Host {
    /// The Recent entry a web tab writes after its first page: an UNSAVED tab
    /// is named after the page's title (a Thai title as it is — before, the
    /// entry was named after the bare address, so the page the user knew by
    /// its title seemed missing from Recent); a saved host keeps its name.
    func recentEntry(pageTitle: String?, isSaved: Bool) -> Host {
        guard !isSaved else { return self }
        let title = ConfigurationHygiene.cleanedName(pageTitle ?? "")
        guard !title.isEmpty else { return self }
        var copy = self
        copy.name = title
        return copy
    }

    /// File / ＋ → New Web Tab: an empty tab (no URL yet). Not saved, not a
    /// recent until a page loads (`adoptingTypedURL` gives it one).
    static func emptyWebTab() -> Host {
        Host(name: "New Tab", kind: .web, address: "", port: 443)
    }

    /// An UNSAVED web tab (New Web Tab, a Quick Search URL) follows what the
    /// user types into its URL field: the address, the name and the port are
    /// the new URL's, so its recent, its title and a "Trust & Connect" are
    /// about the site actually shown. A certificate trusted for another origin
    /// does not come along. A saved host never changes this way.
    func adoptingTypedURL(_ normalized: String) -> Host {
        var copy = self
        if !WebAddress.sameOrigin(address, normalized) {
            // Nothing of the old site follows the new one: not its
            // certificate, and not its login (Fill Login would hand the old
            // host's credentials to whatever was typed).
            copy.webTrustedCertSHA256 = nil
            copy.username = ""
            copy.credentialID = nil
        }
        copy.address = normalized
        copy.name = WebAddress.displayHost(of: normalized)
        copy.port = WebAddress.effectivePort(of: normalized)
        return copy
    }

    /// The saved host a web tab belongs to: the same id, or — a tab opened
    /// from Recents carries a fresh id — the same connection. nil = unsaved.
    static func savedHost(for tab: Host, in saved: [Host]) -> Host? {
        saved.first { $0.id == tab.id } ?? saved.first { $0.kind == tab.kind && $0.connectionKey == tab.connectionKey }
    }

    /// "Save as Host…" on a web tab: the Add Host form prefilled with the
    /// page's title (or its host) and its URL. Only http(s) pages; nil for an
    /// empty tab.
    static func saveAsHostPrefill(pageURL: String?, title: String?) -> (name: String, url: String)? {
        guard let pageURL, WebAddress.isLoadable(URL(string: pageURL)),
              case .success(let url) = WebAddress.normalize(pageURL) else { return nil }
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ConfigurationHygiene.cleanedName(trimmed)
        return (name.isEmpty ? WebAddress.displayHost(of: url) : name, url)
    }

    /// A web host for `url` (already normalised or not): nil when the URL is
    /// refused. Port = the URL's effective port (informational).
    /// `user:pass@` never stays in the address: the name in it becomes the
    /// username when none was given; a password is dropped (the forms refuse
    /// it first — `WebAddress.problem`).
    static func web(name: String, url: String, username: String = "", credentialID: UUID? = nil) -> Host? {
        guard case .success(let result) = WebAddress.normalizeDetailed(url) else { return nil }
        let normalized = result.url
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.isEmpty ? (result.user ?? "") : username
        return Host(name: trimmed.isEmpty ? WebAddress.displayHost(of: normalized) : trimmed,
                    kind: .web, address: normalized, port: WebAddress.effectivePort(of: normalized),
                    username: user, credentialID: credentialID)
    }
}

/// The web bar's URL field: its text area loses the notice's width (plus a
/// gap) while a notice is shown, so the two never overlap.
nonisolated enum WebBarGeometry {
    static let textInset: CGFloat = 8
    static let noticeGap: CGFloat = 6

    static func urlTextWidth(fieldWidth: CGFloat, noticeWidth: CGFloat?) -> CGFloat {
        var width = fieldWidth - 2 * textInset
        if let noticeWidth { width -= noticeWidth + noticeGap }
        return max(20, width)
    }
}

/// W4: JavaScript dialogs (alert / confirm / prompt) per tab. A page may not
/// flood the user: more than `limit` within `window` seconds and the rest are
/// answered automatically (OK / false / nil) with a bar notice, until the
/// main frame navigates.
nonisolated struct WebDialogGate: Sendable {
    static let limit = 3
    static let window: TimeInterval = 10
    private var shown: [TimeInterval] = []
    private(set) var suppressed = false

    init() {}

    /// true = show this dialog; false = answer it automatically.
    mutating func allow(at now: TimeInterval) -> Bool {
        if suppressed { return false }
        shown.removeAll { now - $0 > Self.window }
        guard shown.count < Self.limit else { suppressed = true; return false }
        shown.append(now)
        return true
    }

    mutating func mainFrameNavigated() {
        shown.removeAll()
        suppressed = false
    }
}

/// W8: what a SUBFRAME may load. Main frames are http(s) only (about:blank
/// aside); a subframe may also be about:, blob: or data: — never file:,
/// javascript:, a custom app scheme or anything that hands off to another app.
nonisolated enum WebFramePolicy {
    static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url else { return mainFrame }
        if WebAddress.isLoadable(url) { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        if mainFrame { return url.absoluteString == "about:blank" }
        return ["about", "blob", "data"].contains(scheme)
    }
}

/// W7: a download goes to a temporary name beside its destination and
/// replaces the destination only when it finished — a failed or cancelled
/// download leaves the file that was there.
nonisolated enum WebDownloadPath {
    static func temporary(for destination: URL, token: String = UUID().uuidString) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).sheepterm-\(token.prefix(8)).download")
    }

    /// Move the finished temporary file over the destination (atomically
    /// replacing one that exists).
    static func finish(temporary: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    static func discard(temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
    }
}
