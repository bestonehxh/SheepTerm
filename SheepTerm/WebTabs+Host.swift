import Foundation

// Web tabs, the app-model side: how a `Host` (Models.swift) becomes, follows
// and is saved from a web tab. Mac app only — the pure rules it uses are in
// `WebTabs.swift` (sharedSources, also compiled by SheepTerm for Windows).

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
