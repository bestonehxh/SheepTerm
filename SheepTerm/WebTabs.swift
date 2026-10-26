import Foundation
#if os(Windows)
// Only what WebDownloadPath.finish needs: a whole `import WinSDK` makes
// `UUID` ambiguous (WinSDK has its own) in the rest of this shared file.
import func WinSDK.MoveFileExW
import var WinSDK.MOVEFILE_REPLACE_EXISTING
import var WinSDK.MOVEFILE_WRITE_THROUGH
import typealias WinSDK.DWORD
#endif
#if canImport(SheepWebScripts)
import SheepWebScripts
#endif

// Web tabs (ConnectionKind.web): the pure rules — URL normalisation, origin
// matching for Fill Login, the certificate-trust decision and the Fill Login
// script. Foundation only and in `sharedSources` (root Package.swift): SheepTerm
// for Windows compiles THIS file, so nothing here may name an app type (the
// `Host` side is `WebTabs+Host.swift`) or a Darwin-only API. Tests/run.sh
// compiles it (SRC) and `Tests/tests/WebTabTests.swift` holds every rule to its
// cases. The app side is `WebTabController.swift` / `WebHostSheet.swift`.
// The login-field scripts are `WebLoginScripts` in Packages/SheepWeb/Sources/SheepWebScripts
// (shared with the other Sheep apps; the root Package.swift and Tests/run.sh compile that file too).
// ARCHITECTURE.md "Web tabs" and "Shared with Windows".

/// What a web host's address field may hold, and how it is stored.
public nonisolated enum WebAddress {
    public enum Problem: Error, Equatable, Sendable {
        case empty, whitespace, scheme, invalid
        /// `https://user:pass@host` — the password belongs in a credential.
        case passwordInURL

        /// The short line under the field.
        public var message: String {
            switch self {
            case .empty: return "Enter a URL"
            case .whitespace: return "URL must not contain spaces"
            case .scheme: return "Only http:// and https:// are supported"
            case .invalid: return "Not a valid URL"
            case .passwordInURL: return "Put the password in a credential, not the URL"
            }
        }
    }

    public static let schemes: Set<String> = ["http", "https"]

    /// True when `text` starts with `http://` or `https://` (any case) — what
    /// the connect box / Quick Search / Add Hosts read as "a web target".
    public static func hasWebScheme(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// The URL to store for what the user typed: no scheme → `https://`;
    /// only http/https; a host is required; an explicit port must be 1–65535.
    /// The scheme and host are lower-cased; path, query and fragment are kept.
    public static func normalize(_ text: String) -> Result<String, Problem> {
        normalizeDetailed(text).map(\.url)
    }

    /// `normalize` plus what was taken OUT of the URL: user info never stays
    /// in a stored address (hosts.json is plaintext; the sidebar and recents
    /// show the address). `user` = the name that was in it (the form keeps it
    /// as the host's username when that field is empty); `hadPassword` = a
    /// password was in it (the forms refuse it: `problem` says so).
    public static func normalizeDetailed(_ text: String) -> Result<(url: String, user: String?, hadPassword: Bool), Problem> {
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
    public static func problem(_ text: String) -> Problem? {
        switch normalizeDetailed(text) {
        case .failure(let problem): return problem
        case .success(let result): return result.hadPassword ? .passwordInURL : nil
        }
    }

    /// Defensive: an address from a file, a share, a backup or Sync without
    /// any `user:pass@`. Unparseable text is returned as it was.
    public static func strippingUserInfo(_ address: String) -> String {
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
    public static func textuallyStrippingUserInfo(_ text: String) -> String {
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
    public static func isLoadable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }

    /// The port a web host is stored with — the URL's effective port. Not
    /// used to connect (WebKit reads the URL); kept so `connectionKey` and
    /// the Windows port see a real number.
    public static func effectivePort(of urlString: String) -> Int {
        origin(of: urlString)?.port ?? 443
    }

    /// The URL without its scheme and a lone trailing "/" — the sidebar's
    /// detail line ("10.0.0.1:8443/admin").
    public static func shortLabel(_ urlString: String) -> String {
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
    public static func displayHost(of urlString: String) -> String {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { return urlString }
        return displayHostLabels(components) ?? urlString
    }

    /// What the web tab's URL field does with what was typed (2026-10-15:
    /// "like a browser" — the field is also a Google search box).
    public enum Typed: Equatable, Sendable {
        case empty
        /// Load this (already normalised) URL.
        case url(String)
        /// http(s):// typed but not a usable URL: say why.
        case invalid(Problem)
        /// Search for the text.
        case search(String)
    }

    public static let searchBase = "https://www.google.com/search?q="

    /// The rule: a typed http(s):// scheme → that URL (or why not); otherwise
    /// something host-shaped — a dot in the host, `localhost`, a bracketed
    /// IPv6, with an optional :port and path, no spaces (`10.1.1.1`,
    /// `fw.lab:8443/login`, `ไทย.th`) → https:// + it, as before; ANYTHING else
    /// (spaces, one word without a dot, a question, another scheme) → a search.
    public static func classifyTyped(_ text: String) -> Typed {
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
    public static func isSearchResultsURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        return components.host?.lowercased() == "www.google.com" && components.path == "/search"
    }

    /// The authority part of a scheme-less entry is host-shaped.
    public static func looksLikeHost(_ text: String) -> Bool {
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
    public static func searchURL(for query: String) -> String {
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
    public static func displayURL(_ urlString: String) -> String {
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
    public static func displayDecoded(_ part: String) -> String {
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
                 .unassigned, .surrogate:
                return true
            case .nonspacingMark where v == 0x034F || (0xFE00...0xFE0F).contains(v):
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
    public static let decodableScriptRanges: [ClosedRange<UInt32>] = [
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
    public static func labelIsDisplayable(_ label: Substring) -> Bool {
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

    public static func displayHostLabels(_ components: URLComponents) -> String? {
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
    public struct ServerKey: Hashable, Sendable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) {
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

    public static func serverKey(of urlString: String) -> ServerKey? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme, let fallback = defaultPort(forScheme: scheme),
              let host = components.url?.host() ?? components.host, !host.isEmpty else { return nil }
        return ServerKey(host: host, port: components.port ?? fallback)
    }

    public static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// scheme + host + port, the browser's same-origin key.
    public struct Origin: Equatable, Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int

        public init(scheme: String, host: String, port: Int) {
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }

    /// The origin of a URL string: scheme and host lower-cased, IPv6
    /// brackets removed, the default port filled in (80/443). nil for
    /// anything that is not http/https with a host.
    public static func origin(of urlString: String) -> Origin? {
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
    public static func sameOrigin(_ a: String, _ b: String) -> Bool {
        guard let left = origin(of: a), let right = origin(of: b) else { return false }
        return left == right
    }
}

/// The certificate decision for a web tab (5.0 web tabs). Inputs only, so
/// every branch is a harness case: did the system trust the chain, the leaf's
/// SHA-256, the hash stored on the saved host, and the hashes accepted
/// "Connect Once" in this tab.
public nonisolated enum WebTrust {
    public enum Decision: Equatable, Sendable {
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
    public struct OnceKey: Hashable, Sendable {
        public let host: String
        public let port: Int
        public let hash: String

        public init(host: String, port: Int, hash: String) {
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
    public static func isMainTarget(host: String, port: Int, mainURL: String?) -> Bool {
        guard let mainURL, let main = WebAddress.serverKey(of: mainURL) else { return false }
        return WebAddress.ServerKey(host: host, port: port) == main
    }

    /// The whole answer to one challenge: the system's verdict, then the
    /// main-frame scope, then `decide`.
    public enum ChallengeAction: Equatable, Sendable {
        /// System-trusted: WebKit's default handling.
        case useDefault
        /// Untrusted, not the main frame's server: cancel, no card.
        case block
        case decided(Decision)
    }

    public static func action(systemTrusted: Bool, isMainTarget: Bool, leafSHA256: String, stored: String?,
                       acceptedOnce: Set<OnceKey>, host: String, port: Int) -> ChallengeAction {
        if systemTrusted { return .useDefault }
        guard isMainTarget else { return .block }
        return .decided(decide(systemTrusted: false, leafSHA256: leafSHA256, stored: stored,
                               acceptedOnce: acceptedOnce, host: host, port: port))
    }

    public static func decide(systemTrusted: Bool, leafSHA256: String, stored: String?,
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
    public struct Refusals: Sendable {
        private var refused: Set<String> = []
        public init() {}
        public static func key(host: String, port: Int) -> String { OnceKey(host: host, port: port, hash: "").host + ":\(port)" }
        public mutating func refuse(host: String, port: Int) { refused.insert(Self.key(host: host, port: port)) }
        public func isRefused(host: String, port: Int) -> Bool { refused.contains(Self.key(host: host, port: port)) }
        public mutating func newNavigation() { refused.removeAll() }
    }

    /// Lowercase hex, no separators: what `webTrustedCertSHA256` stores.
    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The card's two lines: upper-case byte pairs with colons, 16 bytes a
    /// line (how browsers and device CLIs print a certificate fingerprint).
    public static func displayLines(_ hex: String) -> (String, String) {
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
/// The key in a login field (5.0 (23), Safari's): what its menu lists, and
/// when a login the user typed is offered for saving. Pure — the page side is
/// `WebLoginKey.script`, run in the app's own content world.
public nonisolated enum WebLoginKey {
    /// One saved login as the menu shows it (no password — that is read only
    /// when the item is picked). `websites` = its sites (`siteKey` form).
    public struct Login: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let username: String
        public let websites: [String]
        public init(id: UUID, name: String, username: String, websites: [String] = []) {
            self.id = id; self.name = name; self.username = username; self.websites = websites
        }
        /// "admin — Lab FortiGate"; the name alone when there is no user.
        public var title: String { username.isEmpty ? name : "\(username) — \(name)" }
    }

    /// A page or a saved address as a site: "scheme://host:port", the port
    /// always written (80/443 filled in), host lower-case, IPv6 in brackets
    /// (so the key parses back to itself) — the same origin rule Fill Login
    /// uses. nil when unparseable or not http(s).
    public static func siteKey(_ url: String) -> String? {
        guard let origin = WebAddress.origin(of: url), origin.scheme == "http" || origin.scheme == "https" else { return nil }
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
        return "\(origin.scheme)://\(host):\(origin.port)"
    }

    /// A credential's list as stored: each entry normalised, unparseable
    /// ones dropped, duplicates gone, order kept.
    public static func cleanedSites(_ sites: [String]) -> [String] {
        var out: [String] = []
        for site in sites {
            guard let key = siteKey(site), !out.contains(key) else { continue }
            out.append(key)
        }
        return out
    }

    /// The menu: the logins for THIS page — the saved host's own credential
    /// (on the host's own address, or a site it lists), then every credential
    /// that lists the page's site; every other login behind "Other Logins".
    /// Off those, the host's own credential is not offered at all (picking it
    /// would only be refused).
    public static func menu(hostCredential: UUID?, hostAddress: String?, page: String?, all: [Login]) -> (site: [Login], others: [Login]) {
        let site = page.flatMap(siteKey)
        let byName: (Login, Login) -> Bool = { ($0.name.localizedLowercase, $0.username) < ($1.name.localizedLowercase, $1.username) }
        let onHost = page.map { page in hostAddress.map { WebAddress.sameOrigin(page, $0) } ?? false } ?? false
        let hostLogin = all.filter { $0.id == hostCredential }
        let own = hostLogin.filter { onHost || site.map($0.websites.contains) == true }
        let forSite = all.filter { $0.id != hostCredential && site.map($0.websites.contains) == true }.sorted(by: byName)
        let mine = Set((own + forSite + hostLogin).map(\.id))
        return (own + forSite, all.filter { !mine.contains($0.id) }.sorted(by: byName))
    }

    /// Whether `login` may be filled into `page` as a site login (its own
    /// address): the saved host's credential on the host's origin, or a
    /// credential that lists the page's site.
    public static func isSiteLogin(_ login: Login, page: String, hostCredential: UUID?, hostAddress: String?) -> Bool {
        if login.id == hostCredential, let hostAddress, WebAddress.sameOrigin(page, hostAddress) { return true }
        guard let site = siteKey(page) else { return false }
        return login.websites.contains(site)
    }

    /// The key is drawn only at 100 % magnification (pinch / smart zoom):
    /// zoomed in, the visible part of the page is shifted by the zoom centre,
    /// which the key's placement does not know. Page zoom (⌘=) is fine.
    public static func keysShown(magnification: Double) -> Bool {
        abs(magnification - 1) < 0.001
    }

    /// The page just changed size (the sidebar or the AI panel came or went,
    /// a pane or window resize — width OR height): its login field moves only once the page has laid
    /// itself out again and reported the new box, so the key hides now and is
    /// placed again `settle` s after the width stopped changing — never left
    /// behind at the old place (the user: the key lagged behind).
    public struct KeyResizeGate: Sendable {
        public static let settle: Double = 0.25
        public private(set) var width: Double = 0
        public private(set) var height: Double = 0
        public init() {}
        /// true = place the key now; false = the size changed: hide it and look again later.
        public mutating func mayPlace(width: Double, height: Double) -> Bool {
            defer { self.width = width; self.height = height }
            return self.width == 0 || (abs(width - self.width) < 0.5 && abs(height - self.height) < 0.5)
        }
    }

    /// After a smart zoom the key is looked at again at these delays (s):
    /// the zoom lands after a round trip to the page plus its animation, and
    /// a busy page can take longer than any single guess.
    /// (No 0.25 s look: a zoom still animating then reads 100 % and flashed the key.)
    public static let smartZoomChecks: [Double] = [0.5, 1, 2]

    /// A link to `a` from the page at `b` stays in the same document: `a`
    /// has a #fragment and the two are equal once it is cut off (a link to
    /// "#" or "#top"). The same address WITHOUT a fragment is a new load —
    /// WebKit's own rule.
    public static func sameDocument(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a.contains("#") else { return false }
        func cut(_ s: String) -> String { s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s }
        return cut(a) == cut(b)
    }

    /// The key shows only when there is something to pick.
    public static func showsKey(savedLogins: Int) -> Bool { savedLogins > 0 }

    public enum Offer: Equatable, Sendable {
        /// Nothing to ask.
        case none
        /// "Save login for <host>?" — a new credential.
        case save
        /// "Update password?" — this credential (same user, other password).
        case update(UUID)
    }

    /// After a login the user TYPED went through (the page then has no
    /// password field any more): what to offer. `hostLogin` = the saved
    /// host's credential (its user and current password, nil = not readable
    /// without a Keychain prompt), nil when the tab has none; `alreadySaved`
    /// = some credential already holds exactly this user + password;
    /// `declined` = Not Now was answered for this origin in this tab.
    public static func offer(username: String, password: String,
                             hostLogin: (id: UUID, username: String, password: String?)?,
                             alreadySaved: Bool = false, declined: Bool) -> Offer {
        guard !password.isEmpty, !declined, !alreadySaved else { return .none }
        if let hostLogin, hostLogin.username == username {
            // Not readable now: never offer to overwrite what we cannot compare.
            guard let saved = hostLogin.password else { return .none }
            return saved == password ? .none : .update(hostLogin.id)
        }
        return .save
    }

    /// A two-step sign-in: the user name sent on the first step, kept for the
    /// password step that shows none (5.0 (53)). Used only on the same site,
    /// within `stepUserLifetime` s, and only when the password step named no user.
    public static let stepUserLifetime: Double = 600
    public static func userForSave(typed: String, step: (site: String, user: String, at: Double)?,
                                   site: String?, now: Double) -> String {
        guard typed.isEmpty, let step, let site, step.site == site, now - step.at >= 0,
              now - step.at < stepUserLifetime else { return typed }
        return step.user
    }

    /// The login went through when the page — after the submit settled — no
    /// longer shows a password field.
    public static func loggedIn(passwordFieldVisible: Bool) -> Bool { !passwordFieldVisible }

    /// Where the key sits: inside the field's right edge, centred, in the
    /// tab's coordinates. `field` is the input's box in CSS pixels from the
    /// page's top-left; `zoom` = page zoom × magnification; `web` = the web
    /// view's frame in the tab (top-left origin).
    /// The key button (its size kept; 5.0 (27) made it a solid accent pill so it is noticed).
    public static let keySize: Double = 18
    public static func keyFrame(field: (x: Double, y: Double, w: Double, h: Double), zoom: Double,
                                web: (x: Double, y: Double, w: Double, h: Double)) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard field.w > 0, field.h > 0, zoom > 0 else { return nil }
        let left = web.x + field.x * zoom, top = web.y + field.y * zoom
        let width = field.w * zoom, height = field.h * zoom
        guard width >= keySize + 8 else { return nil }
        let x = left + width - keySize - 4
        let y = top + (height - keySize) / 2
        // Off the visible page (scrolled away, under the bar): no key.
        guard y >= web.y, y + keySize <= web.y + web.h, x >= web.x, x + keySize <= web.x + web.w else { return nil }
        return (x, y, keySize, keySize)
    }

    /// Runs in the app's own `WKContentWorld` (the page cannot see it or call
    /// the handler): reports the field the key belongs in — the login form's
    /// user field, else its password field (Safari's place); on a page with no
    /// password field, a field that says it is the user name (`userish`: the
    /// first step of a two-step sign-in, 5.0 (53)) — as `fields`
    /// (one box, an empty list when there is no login form), again whenever
    /// it moves or the page changes; and, when a form with a filled password is sent,
    /// what was typed (`submit`); when such a first step is sent, its user name
    /// (`user`) — the password step often shows none. Defines `__sheepLoginCheck()` = a visible
    /// password field is on the page now.
    /// (The script itself lives in the SheepWeb package — `WebLoginScripts`, shared
    /// with the other Sheep apps since 5.0 (53); this name stays for the Windows build.)
    public static let script = WebLoginScripts.pageScript(handler: "sheepLogin")
}

/// Web tab zoom (5.0 (25), Safari's ⌘+ / ⌘−): the steps, and the zoom
/// remembered per site (`WebLoginKey.siteKey`).
public nonisolated enum WebZoom {
    public static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next step up (`delta` > 0) or down from `current`; a value
    /// between steps moves to the nearest one in that direction.
    public static func step(from current: Double, by delta: Int) -> Double {
        if delta > 0 { return steps.first { $0 > current + 0.001 } ?? steps.last! }
        if delta < 0 { return steps.last { $0 < current - 0.001 } ?? steps.first! }
        return current
    }

    /// What is stored for `site`: nothing for 100 % (the default needs no entry).
    public static func remember(_ zoom: Double, for site: String, in table: [String: Double]) -> [String: Double] {
        var out = table
        out[site] = abs(zoom - 1) < 0.001 ? nil : min(max(zoom, steps.first!), steps.last!)
        return out
    }

    public static func zoom(for site: String?, in table: [String: Double]) -> Double {
        guard let site, let value = table[site], value.isFinite else { return 1 }
        return min(max(value, steps.first!), steps.last!)
    }
}

/// The web tab's user agent (5.0 (25)): WebKit's own string names no
/// browser, and old device admin pages pick a different (often broken) code
/// path for it. Appending Safari's tail — the version of the Safari on this
/// Mac — makes them serve what Safari gets.
public nonisolated enum WebUserAgent {
    public static func applicationName(safariVersion: String?) -> String {
        let version = safariVersion.flatMap { v -> String? in
            let digits = v.split(separator: ".").prefix(2).filter { $0.allSatisfy(\.isNumber) }
            return digits.isEmpty ? nil : digits.joined(separator: ".")
        } ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }
}

public nonisolated enum WebFillLogin {
    /// Run with `callAsyncJavaScript(_:arguments:in:contentWorld:)`; the
    /// values arrive as the JSON-encoded arguments `user` and `pass`, never
    /// spliced into the source. Finds the first VISIBLE password input and
    /// the last visible text/email input before it (no password field: the
    /// first field that says it is the user name — a two-step sign-in's first
    /// step), sets their values with the
    /// native setter (so frameworks that track `value` see a change) and
    /// dispatches input + change. Returns "filled", "user-only" or "none".
    /// (The script itself lives in the SheepWeb package — `WebLoginScripts.fillScript`,
    /// shared with the other Sheep apps since 5.0 (53). Since then it runs in the app's own world.)
    public static let script = WebLoginScripts.fillScript

    public enum Refusal: Equatable, Sendable {
        case noLogin, otherOrigin, noPage, loading

        public var message: String {
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
    public static func check(pageURL: String?, savedURL: String, username: String, hasPassword: Bool,
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
    public static func isProvisional(currentURL: String?, committedURL: String?) -> Bool {
        guard let currentURL, let committedURL else { return true }
        return !WebAddress.sameOrigin(currentURL, committedURL)
    }

    /// The `expected` argument of `script`: the saved URL's origin in
    /// `location`'s terms (protocol with its colon, bare host, port string).
    public static func expectedOrigin(savedURL: String) -> [String: String]? {
        guard let origin = WebAddress.origin(of: savedURL) else { return nil }
        return ["protocol": origin.scheme + ":", "hostname": origin.host, "port": String(origin.port)]
    }

    /// The script's answer, as the tab reports it (nil = done).
    public static func outcome(_ value: String?) -> Refusal? {
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
public nonisolated enum WebRecentRename {
    public static func shouldRename(notedName: String?, alreadyRenamed: Bool, newName: String,
                             pageURL: String?, recentAddress: String) -> Bool {
        guard let notedName, !alreadyRenamed, newName != notedName, let pageURL,
              !WebAddress.isSearchResultsURL(recentAddress) else { return false }
        return WebAddress.sameOrigin(pageURL, recentAddress)
    }
}

/// The web bar's URL field: its text area loses the notice's width (plus a
/// gap) while a notice is shown, so the two never overlap.
public nonisolated enum WebBarGeometry {
    public static let textInset: CGFloat = 8
    public static let noticeGap: CGFloat = 6

    public static func urlTextWidth(fieldWidth: CGFloat, noticeWidth: CGFloat?) -> CGFloat {
        var width = fieldWidth - 2 * textInset
        if let noticeWidth { width -= noticeWidth + noticeGap }
        return max(20, width)
    }
}

/// W4: JavaScript dialogs (alert / confirm / prompt) per tab. A page may not
/// flood the user: more than `limit` within `window` seconds and the rest are
/// answered automatically (OK / false / nil) with a bar notice, until the
/// main frame navigates.
public nonisolated struct WebDialogGate: Sendable {
    public static let limit = 3
    public static let window: TimeInterval = 10
    private var shown: [TimeInterval] = []
    public private(set) var suppressed = false

    public init() {}

    /// true = show this dialog; false = answer it automatically.
    public mutating func allow(at now: TimeInterval) -> Bool {
        if suppressed { return false }
        shown.removeAll { now - $0 > Self.window }
        guard shown.count < Self.limit else { suppressed = true; return false }
        shown.append(now)
        return true
    }

    public mutating func mainFrameNavigated() {
        shown.removeAll()
        suppressed = false
    }
}

/// W8: what a SUBFRAME may load. Main frames are http(s) only (about:blank
/// aside); a subframe may also be about:, blob: or data: — never file:,
/// javascript:, a custom app scheme or anything that hands off to another app.
public nonisolated enum WebFramePolicy {
    public static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
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
public nonisolated enum WebDownloadPath {
    public static func temporary(for destination: URL, token: String = UUID().uuidString) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).sheepterm-\(token.prefix(8)).download")
    }

    /// Move the finished temporary file over the destination (atomically
    /// replacing one that exists).
    public static func finish(temporary: URL, destination: URL) throws {
        #if os(Windows)
        // Foundation's replaceItemAt is "not yet implemented" on Windows (it
        // throws): MoveFileEx with REPLACE_EXISTING is the atomic replace there.
        let ok = temporary.path.withCString(encodedAs: UTF16.self) { from in
            destination.path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path]) }
        #else
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        #endif
    }

    public static func discard(temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
    }
}
