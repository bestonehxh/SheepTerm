import AppKit
import Combine
import CryptoKit
import SwiftUI
import WebKit

/// A web tab (ConnectionKind.web): a WKWebView under a slim bar, living in a
/// pane like a terminal does (`PaneContent` — reparented, never recreated).
/// The rules it applies are pure and harness-tested in WebTabs.swift
/// (`WebAddress`, `WebTrust`, `WebFillLogin`); ARCHITECTURE.md "Web tabs".
///
/// - Cookies/sessions persist in `WKWebsiteDataStore.default()` (View →
///   Clear Website Data… empties it).
/// - One `WKScriptMessageHandler` (`sheepLogin`), and only in the app's own
///   content world (`loginWorld`): the page's scripts can neither see nor
///   call it. It carries the login field's box (the key) and what the user
///   typed into a login form (Save login) — never anything to run.
/// - Never a session log, never highlight/snippets/broadcast/history.
@MainActor
final class WebTabController: NSObject {
    /// The host this tab was opened for. `address` is the saved URL — the
    /// origin Fill Login and the stored certificate belong to.
    private(set) var host: Host
    let view: WebTabView
    let webView: SheepWebView

    var onTitleChange: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The keyboard went into this tab (page, bar, card).
    var onFocus: (() -> Void)?
    /// First page that finished loading (recents).
    var onFirstLoad: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var didFirstLoad = false
    private var closed = false

    /// "Connect Once" answers in this tab: server (host + port) AND
    /// certificate. (WebKit's network session also remembers an accepted
    /// trust for that host:port for the rest of this app run.)
    private var acceptedOnce = Set<WebTrust.OnceKey>()
    /// Servers refused in the current main-frame navigation (no card cascade).
    private var refusals = WebTrust.Refusals()
    /// Page dialogs: rate-limited per tab, shown as sheets on this window.
    private var dialogGate = WebDialogGate()
    private weak var dialogSheet: NSWindow?
    /// Downloads in flight: the temporary file each one writes and where it goes.
    /// The URL of the document on screen (set at commit).
    private var committedURL: String?
    private var downloads: [ObjectIdentifier: (download: WKDownload, temporary: URL?, destination: URL?)] = [:]
    /// One certificate card at a time; other challenges wait their turn and
    /// are decided again afterwards (the answer may cover them).
    private var cardBusy = false
    private var cardWaiters: [CheckedContinuation<Void, Never>] = []
    private var cardAnswer: CheckedContinuation<ConnectionPromptReply, Never>?
    private var card: ConnectionCardView?
    private var overlay: ConnectionOverlayView?

    // MARK: login key + Save login (5.0 (23))

    /// The app's own JavaScript world: `WebLoginKey.script` and its handler
    /// live here, out of the page's reach.
    static let loginWorld = WKContentWorld.world(name: "SheepTermLogin")
    private let loginProxy = WebLoginMessageProxy()
    /// A login form the user sent, until the page says whether it went
    /// through. The password lives only here (memory) and in the question.
    private var pendingLogin: (origin: String, username: String, password: String)?
    private var loginCheckGeneration = 0
    /// Not Now was answered for these origins in this tab.
    private var declinedSaveOrigins = Set<String>()
    /// The login last put in from the key's menu, as a hash (equality is all
    /// it is for — no second plaintext copy): sending exactly that is not a
    /// new login to offer.
    private var filledFromKey: SHA256.Digest?
    /// The key's field as the page last reported it (CSS px): re-placed on
    /// every layout of the tab and whenever the saved logins change.
    private var keyBoxes: [(x: Double, y: Double, w: Double, h: Double)] = []
    private var credentialsWatch: AnyCancellable?
    /// When the pending login was sent: it is given up after a minute.
    private var pendingSince = Date.distantPast

    private static func digest(_ username: String, _ password: String) -> SHA256.Digest {
        SHA256.hash(data: Data((username + "\u{0}" + password).utf8))
    }

    /// The URL the page is on (or the saved one before anything loaded).
    var currentURL: String { webView.url?.absoluteString ?? host.address }

    /// A New Web Tab with nothing typed yet: no page at all.
    var isEmpty: Bool { webView.url == nil && host.address.isEmpty }

    /// "Save as Host…": what the Add Host form starts with (nil = nothing to save).
    var saveAsHostPrefill: (name: String, url: String)? {
        Host.saveAsHostPrefill(pageURL: webView.url?.absoluteString, title: webView.title)
    }

    init(host: Host) {
        self.host = host
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebLoginKey.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                         in: Self.loginWorld))
        configuration.userContentController.add(loginProxy, contentWorld: Self.loginWorld, name: "sheepLogin")
        webView = SheepWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 480), configuration: configuration)
        view = WebTabView(webView: webView)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.onFocus = { [weak self] in self?.onFocus?() }
        webView.isHidden = host.address.isEmpty
        view.bar.controller = self
        loginProxy.controller = self
        view.onKey = { [weak self] button in self?.showLoginMenu(from: button) }
        view.onLayout = { [weak self] in self?.placeKeys() }
        credentialsWatch = AppModel.shared.credentialStore.$credentials
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.placeKeys() } }
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.titleChanged() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.view.bar.refresh() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.view.bar.refresh() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.view.bar.refresh() } },
        ]
    }

    func start() {
        // New Web Tab: nothing to load — the bar, its URL field (focused by
        // the pane: `keyView`) and the chrome behind an empty page.
        if host.address.isEmpty {
            onStatus?("new tab")
            view.bar.refresh()
            return
        }
        guard let url = URL(string: host.address), WebAddress.isLoadable(url) else {
            onStatus?("failed — not an http(s) address")
            return
        }
        onStatus?("loading \(WebAddress.displayHost(of: host.address))…")
        webView.load(URLRequest(url: url))
        view.bar.refresh()
    }

    /// The tab is closing: stop, answer any waiting question, let go.
    func close() {
        closed = true
        settleCard(.cancel)
        // A page dialog still up: end it (its handler answers Cancel).
        if let sheet = dialogSheet, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .abort) }
        dialogSheet = nil
        // Downloads in flight stop; their temporary files go, the files they
        // would have replaced stay.
        for entry in downloads.values {
            entry.download.cancel { _ in }
            if let temporary = entry.temporary { WebDownloadPath.discard(temporary: temporary) }
        }
        downloads.removeAll()
        for waiter in cardWaiters { waiter.resume() }
        cardWaiters.removeAll()
        observations.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sheepLogin", contentWorld: Self.loginWorld)
        loginProxy.controller = nil
        pendingLogin = nil
        filledFromKey = nil
        keyBoxes = []
        credentialsWatch = nil
        view.showKeys(at: [])
        view.bar.hidePrompt()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        view.bar.controller = nil
    }

    private func urlChanged() {
        // An empty tab shows the chrome, not WebKit's white page.
        webView.isHidden = webView.url == nil
        view.bar.refresh()
    }

    private func titleChanged() {
        let title = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onTitleChange?(String((title.isEmpty ? host.name : title).prefix(256)))
        // The title can land after didFinish (measured: the first page's
        // recent was written with the bare address): rename the recent once
        // it is known, and only when the name actually changes.
        let entry = recentEntry
        if didFirstLoad, WebRecentRename.shouldRename(notedName: notedRecentName, alreadyRenamed: recentRenamed,
                                                      newName: entry.name, pageURL: webView.url?.absoluteString,
                                                      recentAddress: entry.address) {
            recentRenamed = true
            onRecentRename?()
        }
    }

    /// The name the Recent entry was last written with (nil = not yet).
    var notedRecentName: String?
    /// The one rename has happened (`WebRecentRename`).
    private var recentRenamed = false
    /// The recent's name changed (`Host.recentEntry`): write it again.
    var onRecentRename: (() -> Void)?

    // MARK: - bar actions

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }
    func reload() { webView.reload() }

    /// The URL field's Return: only http/https, normalised like the form.
    /// The URL field's Return: an address loads, anything else is a Google
    /// search (`WebAddress.classifyTyped`). A saved host's tab just
    /// navigates — its saved address is never rewritten by what is typed.
    func load(typed text: String) {
        let target: String
        switch WebAddress.classifyTyped(text) {
        case .empty: return
        case .invalid(let problem):
            view.bar.notice(problem.message)
            return
        case .url(let url), .search(let url): target = url
        }
        guard let url = URL(string: target) else { return }
        // The user goes somewhere else: a login sent before is not this page's.
        pendingLogin = nil
        // An unsaved tab follows what is typed (`Host.adoptingTypedURL`):
        // its recent, title and any Trust & Connect are about this site.
        if savedHost == nil {
            host = host.adoptingTypedURL(target)
            if (webView.title ?? "").isEmpty { onTitleChange?(host.name) }
        }
        webView.load(URLRequest(url: url))
        view.window?.makeFirstResponder(webView)
    }


    func focusLocation() { view.bar.focusLocation() }
    func showFind() { view.bar.showFind() }
    func findNext(backwards: Bool) { view.bar.find(backwards: backwards) }

    func openInDefaultBrowser() {
        guard let url = webView.url ?? URL(string: host.address), WebAddress.isLoadable(url) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fill Login

    /// The saved host this tab is: by id, or by connection (a tab opened from
    /// Recents has a fresh id). Read live, so an edit to the saved host
    /// (login, trusted certificate) reaches an open tab.
    private var savedHost: Host? {
        Host.savedHost(for: host, in: AppModel.shared.store.groups.flatMap(\.hosts))
    }

    /// What Fill Login and the certificate check use: the saved host as it is
    /// NOW, else this tab's own (unsaved) host.
    private var liveHost: Host { savedHost ?? host }

    // MARK: - login key (5.0 (23))

    /// From `WebLoginKey.script` (main frame, the app's world only).
    func loginMessage(_ message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let kind = body["k"] as? String else { return }
        switch kind {
        case "fields":
            // The key's field (one box, or none): placed now and again on
            // every layout (`placeKeys`).
            let boxes = (body["boxes"] as? [[String: Any]]) ?? []
            keyBoxes = boxes.compactMap { box in
                guard let x = box["x"] as? Double, let y = box["y"] as? Double,
                      let w = box["w"] as? Double, let h = box["h"] as? Double else { return nil }
                return (x, y, w, h)
            }
            placeKeys()
        case "submit":
            guard let password = body["pass"] as? String, !password.isEmpty,
                  let origin = committedURL, WebAddress.sameOrigin(origin, webView.url?.absoluteString ?? "") else { return }
            pendingLogin = (origin, body["user"] as? String ?? "", password)
            pendingSince = Date()
            loginCheckGeneration &+= 1
            let generation = loginCheckGeneration
            // A full page load is checked at didFinish too; a single-page app
            // (Aruba CX) never navigates, so look again a moment later.
            // 8 s for the last look: a busy device's login check is slow.
            for (delay, last) in [(1.5, false), (4.0, false), (8.0, true)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.checkLogin(generation: generation, last: last)
                }
            }
        default:
            break
        }
    }

    /// The key over its field, from the last box the page reported and the
    /// web view's frame NOW (a pane resize moves the page without moving the
    /// field's CSS box); none without saved logins.
    private func placeKeys() {
        guard !closed, WebLoginKey.showsKey(savedLogins: AppModel.shared.credentialStore.credentials.count) else {
            view.showKeys(at: [])
            return
        }
        let zoom = Double(webView.pageZoom * webView.magnification)
        let web = webView.frame
        view.showKeys(at: keyBoxes.compactMap { box in
            WebLoginKey.keyFrame(field: box, zoom: zoom, web: (web.minX, web.minY, web.width, web.height))
                .map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        })
    }

    /// The key's menu: this host's login first; every other one behind
    /// "Other Logins" — a slip of the mouse cannot put a lab password into
    /// some other page.
    private func showLoginMenu(from button: NSView) {
        let store = AppModel.shared.credentialStore
        let all = store.credentials.map { WebLoginKey.Login(id: $0.id, name: $0.name, username: $0.username) }
        let (own, others) = WebLoginKey.menu(hostCredential: liveHost.credentialID, all: all)
        let menu = NSMenu()
        if let own {
            let item = NSMenuItem(title: own.title, action: #selector(pickLogin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = own.id
            menu.addItem(item)
        }
        if !others.isEmpty {
            let sub = NSMenu()
            for login in others {
                let item = NSMenuItem(title: login.title, action: #selector(pickLogin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = login.id
                sub.addItem(item)
            }
            let holder = NSMenuItem(title: "Other Logins", action: nil, keyEquivalent: "")
            holder.submenu = sub
            menu.addItem(holder)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func pickLogin(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID,
              let credential = AppModel.shared.credentialStore.credential(for: id) else { return }
        fill(credential, ownLogin: id == liveHost.credentialID)
    }

    /// Puts `credential` into the page — never submitted. The host's own
    /// login only on the host's own address; another one (picked by the
    /// user) into the page on screen, never into a page still being replaced.
    private func fill(_ credential: Credential, ownLogin: Bool) {
        let password = AppModel.shared.credentialStore.password(for: credential) ?? ""
        let pageURL = webView.url?.absoluteString
        let target = ownLogin ? liveHost.address : (committedURL ?? "")
        if let refusal = WebFillLogin.check(pageURL: pageURL, savedURL: target, username: credential.username,
                                            hasPassword: !password.isEmpty,
                                            provisional: WebFillLogin.isProvisional(currentURL: pageURL, committedURL: committedURL)) {
            view.bar.notice(refusal.message)
            NSSound.beep()
            return
        }
        // The document itself is checked too (`expected`): `webView.url` can
        // name a page that is not the one on screen yet.
        guard let expected = WebFillLogin.expectedOrigin(savedURL: target) else {
            view.bar.notice(WebFillLogin.Refusal.otherOrigin.message)
            return
        }
        filledFromKey = Self.digest(credential.username, password)
        webView.callAsyncJavaScript(WebFillLogin.script,
                                    arguments: ["user": credential.username, "pass": password, "expected": expected],
                                    in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value as String) where value == "other-origin":
                self.view.bar.notice(WebFillLogin.Refusal.otherOrigin.message)
                NSSound.beep()
            case .success(let value as String) where value == "filled" || value == "user-only":
                break
            case .success:
                self.view.bar.notice("No login form on this page")
            case .failure:
                self.view.bar.notice("Could not fill this page")
            }
        }
    }

    /// After a login form was sent: no password field on the page any more =
    /// it went through → offer to save it. Still one, on a page that has
    /// finished loading, at the last look = it did not. A slow device UI
    /// still loading at the last look is left to didFinish; after a minute
    /// the login is given up whatever happens.
    private func checkLogin(generation: Int, last: Bool) {
        guard !closed, generation == loginCheckGeneration, pendingLogin != nil else { return }
        if Date().timeIntervalSince(pendingSince) > 60 { pendingLogin = nil; return }
        webView.callAsyncJavaScript("return window.__sheepLoginCheck ? window.__sheepLoginCheck() : null",
                                    arguments: [:], in: nil, in: Self.loginWorld) { [weak self] result in
            guard let self, generation == self.loginCheckGeneration, let pending = self.pendingLogin else { return }
            if case .success(let value as Bool) = result, WebLoginKey.loggedIn(passwordFieldVisible: value) {
                self.pendingLogin = nil
                self.offerSave(pending)
            } else if last, !self.webView.isLoading {
                // Still the login form — or no answer at all (the script is
                // gone: a download, a non-HTML page): it did not go through.
                self.pendingLogin = nil
            }
        }
    }

    private func offerSave(_ login: (origin: String, username: String, password: String)) {
        let typed = Self.digest(login.username, login.password)
        defer { filledFromKey = nil }
        if filledFromKey == typed { return }
        let store = AppModel.shared.credentialStore
        let saved = savedHost.flatMap { WebAddress.sameOrigin($0.address, login.origin) ? $0 : nil }
        let hostCredential = saved?.credentialID.flatMap { store.credential(for: $0) }
        let originKey = WebAddress.origin(of: login.origin).map { "\($0.scheme)://\($0.host):\($0.port)" } ?? login.origin
        // Compared without a Keychain prompt: a hand-typed login must not be
        // what makes the vault ask for access.
        // Already saved = some credential holds this user and password — or
        // holds this user with a password not readable without a prompt
        // (right after an update): never risk a duplicate on a guess.
        let alreadySaved = store.credentials.contains {
            guard $0.username == login.username else { return false }
            guard let saved = Keychain.passwordWithoutPrompt(for: $0.id) else { return true }
            return saved == login.password
        }
        let offer = WebLoginKey.offer(username: login.username, password: login.password,
                                      hostLogin: hostCredential.map { ($0.id, $0.username, Keychain.passwordWithoutPrompt(for: $0.id)) },
                                      alreadySaved: alreadySaved,
                                      declined: declinedSaveOrigins.contains(originKey))
        let place = saved?.name ?? WebAddress.displayHost(of: login.origin)
        switch offer {
        case .none:
            return
        case .save:
            view.bar.ask("Save login for \(place)?", action: "Save") { [weak self] yes in
                guard let self else { return }
                guard yes else { self.declinedSaveOrigins.insert(originKey); return }
                let credential = store.add(name: place, username: login.username, password: login.password)
                // A saved host with no login of its own gets this one.
                if var host = self.savedHost, WebAddress.sameOrigin(host.address, login.origin),
                   store.credential(for: host.credentialID) == nil {
                    host.credentialID = credential.id
                    AppModel.shared.store.updateHost(host)
                }
                self.view.bar.notice("Login saved")
            }
        case .update(let id):
            view.bar.ask("Update the password for \(login.username)?", action: "Update") { [weak self] yes in
                guard let self else { return }
                guard yes else { self.declinedSaveOrigins.insert(originKey); return }
                if Keychain.setPassword(login.password, for: id) {
                    self.view.bar.notice("Password updated")
                } else {
                    self.view.bar.notice("The password could not be saved")
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: - certificate card

    /// Waits for the card to be free, then asks. Every challenge that waited
    /// is decided again by its caller once it gets its turn.
    private func waitForCardTurn() async {
        while cardBusy && !closed {
            await withCheckedContinuation { cardWaiters.append($0) }
        }
    }

    private func releaseCardTurn() {
        cardBusy = false
        if !cardWaiters.isEmpty { cardWaiters.removeFirst().resume() }
    }

    private func ask(_ question: WebCertificateQuestion) async -> ConnectionPromptReply {
        await withCheckedContinuation { continuation in
            cardAnswer = continuation
            showCard(question)
        }
    }

    private func showCard(_ question: WebCertificateQuestion) {
        let header = ConnectionCardHeader(title: host.name, subtitle: question.server,
                                          windowTitle: "\(host.name) — \(question.server)")
        let card = ConnectionCardView(header: header)
        card.model.webTrack = true
        card.onFocus = { [weak self] in self?.onFocus?() }
        let overlay = ConnectionOverlayView(frame: view.bounds)
        overlay.card = card
        view.addSubview(overlay)
        overlay.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        self.card = card
        self.overlay = overlay
        card.show(stage: .hostKey, page: .certificate(question)) { [weak self] action in
            switch action {
            case .answer(let reply): self?.settleCard(reply)
            default: self?.settleCard(.cancel)
            }
        }
        // The keyboard only if this tab already had it (the SSH card's rule).
        if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
            card.takeKeyboard()
        }
    }

    private func settleCard(_ reply: ConnectionPromptReply) {
        let hadKeyboard = card?.hasKeyboard ?? false
        card?.removeFromSuperview()
        overlay?.removeFromSuperview()
        card = nil
        overlay = nil
        if hadKeyboard { view.window?.makeFirstResponder(webView) }
        if let answer = cardAnswer {
            cardAnswer = nil
            answer.resume(returning: reply)
        }
    }

    var hasCard: Bool { card != nil }
    var cardHasKeyboard: Bool { card?.hasKeyboard ?? false }
    @discardableResult func focusCard() -> Bool { card?.takeKeyboard() ?? false }

    /// Whether `server` is the saved host's own (scheme-less: host + port).
    private func isSavedServer(host challengeHost: String, port: Int) -> Bool {
        // ServerKey: punycode on both sides — an IDN saved host (`ไทย.th`)
        // and its challenge (`xn--o3cw4h.th`) are the same server.
        guard let saved = WebAddress.serverKey(of: liveHost.address) else { return false }
        return WebAddress.ServerKey(host: challengeHost, port: port) == saved
    }

    /// The server the main frame is going to: the URL of the main-frame
    /// navigation being decided / redirected, else the committed page, else
    /// the host's own address. Only its challenges may show the card.
    private var mainTargetURL: String?
    private var mainFrameURL: String? { mainTargetURL ?? committedURL ?? (liveHost.address.isEmpty ? nil : liveHost.address) }
    /// Untrusted subresource servers blocked in the current navigation (the
    /// bar says so once, naming the first).
    private var blockedThisNavigation = 0

    /// The Recent entry for this tab's first page (`Host.recentEntry`).
    var recentEntry: Host {
        liveHost.recentEntry(pageTitle: webView.title, isSaved: AppModel.shared.savedHost(id: liveHost.id) != nil)
    }

    /// The trust answer was "Trust & Connect": the hash goes on the host —
    /// the saved one in hosts.json when this tab is a saved host's.
    private func storeTrust(_ hash: String) {
        host.webTrustedCertSHA256 = hash
        let model = AppModel.shared
        if var saved = savedHost {
            saved.webTrustedCertSHA256 = hash
            model.store.updateHost(saved)
        }
    }

    fileprivate func decideServerTrust(_ challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let systemTrusted = await Self.evaluate(trust)
        if systemTrusted { return (.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let hash = WebTrust.hex(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        let space = challenge.protectionSpace
        // Browsers never ask about a subresource: only the main frame's own
        // server gets the card; any other untrusted server is cut quietly.
        if WebTrust.action(systemTrusted: false, isMainTarget: WebTrust.isMainTarget(host: space.host, port: space.port,
                                                                                    mainURL: mainFrameURL),
                           leafSHA256: hash, stored: nil, acceptedOnce: acceptedOnce,
                           host: space.host, port: space.port) == .block {
            blockedThisNavigation += 1
            if blockedThisNavigation == 1 {
                let server = space.port == 443 ? space.host : "\(space.host):\(space.port)"
                view.bar.notice("Some page content was blocked (untrusted certificate: \(server))")
            }
            return (.cancelAuthenticationChallenge, nil)
        }
        let own = isSavedServer(host: space.host, port: space.port)
        while true {
            if closed { return (.cancelAuthenticationChallenge, nil) }
            // Refused already in this navigation: no second card.
            if refusals.isRefused(host: space.host, port: space.port) { return (.cancelAuthenticationChallenge, nil) }
            let decision = WebTrust.decide(systemTrusted: false, leafSHA256: hash,
                                           stored: own ? liveHost.webTrustedCertSHA256 : nil, acceptedOnce: acceptedOnce,
                                           host: space.host, port: space.port)
            if decision == .accept { return (.useCredential, URLCredential(trust: trust)) }
            if cardBusy {
                await waitForCardTurn()
                continue
            }
            cardBusy = true
            let server = space.port == 443 ? space.host : "\(space.host):\(space.port)"
            onStatus?("certificate — \(server)")
            let reply = await ask(WebCertificateQuestion(server: server, fingerprint: hash,
                                                         changed: decision == .askChanged, canTrust: own))
            releaseCardTurn()
            switch reply {
            case .trust where own:
                storeTrust(hash)
                acceptedOnce.insert(WebTrust.OnceKey(host: space.host, port: space.port, hash: hash))
                return (.useCredential, URLCredential(trust: trust))
            case .trustOnce:
                acceptedOnce.insert(WebTrust.OnceKey(host: space.host, port: space.port, hash: hash))
                return (.useCredential, URLCredential(trust: trust))
            default:
                refusals.refuse(host: space.host, port: space.port)
                onStatus?("cancelled — certificate not trusted")
                view.bar.notice("Certificate not trusted — nothing loaded")
                return (.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// The system's verdict, off the main thread (revocation checks may go
    /// to the network).
    private static func evaluate(_ trust: SecTrust) async -> Bool {
        nonisolated(unsafe) let trust = trust
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                let ok = SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, _ in
                    continuation.resume(returning: trusted)
                }
                if ok != errSecSuccess { continuation.resume(returning: false) }
            }
        }
    }
}

// MARK: - PaneContent

extension WebTabController: PaneContent {
    var paneView: NSView { view }
    /// The card, else the page — or the URL field while no page is shown
    /// (an empty tab, or a first load that failed).
    var keyView: NSView { card ?? (webView.url == nil ? view.bar.locationField : webView) }
    var hasPrompt: Bool { hasCard }
    var promptHasKeyboard: Bool { cardHasKeyboard }
    func focusPrompt() -> Bool { focusCard() }
    func paneDidHide() { view.bar.hideFind() }
    func setPointerNeedsFocus(_ needsFocus: Bool) {}
    func refreshFocusAppearance() {}
}

// MARK: - WKNavigationDelegate

extension WebTabController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return await decideServerTrust(challenge)
        }
        return (.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // The main frame stays on http/https (about:blank aside); a link to
        // mailto:, ssh:, file: … is refused, not handed to another app.
        // Subframes: also about:, blob:, data: — nothing that hands off to
        // another app or reads local files (`WebFramePolicy`).
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        // A link clicked, Back/Forward or Reload is not where a login lands
        // (a form post, or the page's own script, is): a login sent before
        // and not settled is dropped — never offered on the next page.
        guard WebFramePolicy.allows(navigationAction.request.url, mainFrame: isMain) else {
            if isMain { view.bar.notice("Only http:// and https:// open in a web tab") }
            return (.cancel, preferences)
        }
        // A link to a fragment of the same page (a Bootstrap `<a href="#"
        // role="button">` login) is not leaving it.
        if isMain, pendingLogin != nil,
           [.backForward, .reload].contains(navigationAction.navigationType)
            || (navigationAction.navigationType == .linkActivated
                && !WebLoginKey.sameDocument(navigationAction.request.url?.absoluteString, webView.url?.absoluteString)) {
            pendingLogin = nil
        }
        if isMain { mainTargetURL = navigationAction.request.url?.absoluteString }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse, navigationResponse.isForMainFrame,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (download, nil, nil)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (download, nil, nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new main-frame navigation: a refused certificate may be asked about again.
        refusals.newNavigation()
        blockedThisNavigation = 0
        keyBoxes = []
        view.showKeys(at: [])
        onStatus?("loading \(WebAddress.displayHost(of: currentURL))…")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: its dialogs start from zero.
        dialogGate.mainFrameNavigated()
        committedURL = webView.url?.absoluteString
        mainTargetURL = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onStatus?("web · \(WebAddress.displayHost(of: currentURL))")
        if !didFirstLoad {
            didFirstLoad = true
            onFirstLoad?()
        }
        // A login form sent a moment ago and a new page is in: did it go through?
        if pendingLogin != nil {
            let generation = loginCheckGeneration
            checkLogin(generation: generation, last: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.checkLogin(generation: generation, last: true)
            }
        }
#if DEBUG
        // Screenshot runs only: SHEEPTERM_DEBUG_LOGIN_KEY=focus puts the caret
        // in the page's password field (the key appears); =save also raises
        // Save login's question for a sample login.
        if let mode = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_LOGIN_KEY"] {
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript("document.querySelector('input[type=password]')?.focus()")
            if mode == "save" { offerSave((committedURL ?? currentURL, "admin", "demo-only")) }
        }
#endif
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // A redirect moves the main frame's target (the decidePolicy call for
        // it may not be made for a server redirect).
        if let url = webView.url?.absoluteString { mainTargetURL = url }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
        // The login's own navigation failed (unreachable, certificate
        // refused): it did not go through.
        if !webView.isLoading { pendingLogin = nil }
        // The page on screen stayed: its key comes back.
        webView.callAsyncJavaScript("window.__sheepLoginReport && window.__sheepLoginReport()", arguments: [:],
                                    in: nil, in: Self.loginWorld) { _ in }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onStatus?("failed — the page stopped; reload to try again")
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // A navigation replaced by another (or turned into a download) is
        // not a failure anyone needs to read about.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        onStatus?("failed — \(ns.localizedDescription)")
        view.bar.notice(ns.localizedDescription)
    }
}

// MARK: - WKUIDelegate

extension WebTabController: WKUIDelegate {
    /// window.open / target=_blank: the same tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, WebAddress.isLoadable(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func pageAlert(_ message: String, frame: WKFrameInfo) -> SheepAlert {
        let alert = SheepAlert()
        let origin = frame.securityOrigin.host.isEmpty ? host.name : frame.securityOrigin.host
        alert.messageText = "“\(ConfigurationHygiene.sanitizedName(origin))” says"
        alert.informativeText = String(message.prefix(1_000))
        return alert
    }

    /// Shown as a sheet on this tab's window (never app-modal), at most
    /// `WebDialogGate.limit` per 10 s; the rest get their default answer
    /// and a bar notice. nil = answered automatically (no window, flood).
    private func presentDialog(_ alert: SheepAlert) async -> NSApplication.ModalResponse? {
        guard !closed, let window = view.window, window.attachedSheet == nil, dialogSheet == nil,
              dialogGate.allow(at: ProcessInfo.processInfo.systemUptime) else {
            if dialogGate.suppressed { view.bar.notice("Page dialogs blocked") }
            return nil
        }
        let sheet = alert.window
        dialogSheet = sheet
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if dialogSheet === sheet { dialogSheet = nil }
        return closed ? nil : response
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await presentDialog(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentDialog(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = pageAlert(prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: SheepAlert.contentWidth, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentDialog(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Camera / microphone: never (a device's web UI has no use for them).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = view.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
}

// MARK: - WKDownloadDelegate

extension WebTabController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard !closed else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let answer: NSApplication.ModalResponse
        if let window = view.window { answer = await panel.beginSheetModal(for: window) } else { answer = panel.runModal() }
        guard answer == .OK, let url = panel.url, !closed else { return nil }
        // Written beside the destination under a temporary name; the file
        // that is there now (the panel asked about replacing it) stays until
        // the download has finished.
        let temporary = WebDownloadPath.temporary(for: url)
        downloads[ObjectIdentifier(download)] = (download, temporary, url)
        return temporary
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)),
              let temporary = entry.temporary, let destination = entry.destination else { return }
        do {
            try WebDownloadPath.finish(temporary: temporary, destination: destination)
            view.bar.notice("Download finished")
        } catch {
            WebDownloadPath.discard(temporary: temporary)
            view.bar.notice("Download failed — \(error.localizedDescription)")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let entry = downloads.removeValue(forKey: ObjectIdentifier(download)), let temporary = entry.temporary {
            WebDownloadPath.discard(temporary: temporary)
        }
        guard !closed else { return }
        view.bar.notice("Download failed — \(error.localizedDescription)")
    }
}

/// WKWebView that says when it takes the keyboard (pane focus).
final class SheepWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

/// The tab's view: the bar on top, the page under it, and the login key
/// over a focused login field (5.0 (23) — an app view, so the page can
/// neither see nor restyle it).
final class WebTabView: NSView {
    let bar = WebBarView()
    let webView: WKWebView
    /// The key was clicked (the controller shows the login menu at it).
    var onKey: ((NSView) -> Void)?
    /// Every layout (a pane resize moves the page under a key).
    var onLayout: (() -> Void)?
    /// One key per login field on screen (user, password) — created as needed.
    private var keyButtons: [NSButton] = []

    private func makeKey() -> NSButton {
        let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Saved logins")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(keyClicked(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.contentTintColor = NSColor(Theme.accent)
        button.toolTip = "Saved logins"
        addSubview(button)
        return button
    }

    /// A key at each frame; the rest hidden (an empty list hides them all).
    func showKeys(at frames: [CGRect]) {
        while keyButtons.count < frames.count { keyButtons.append(makeKey()) }
        for (index, button) in keyButtons.enumerated() {
            if index < frames.count {
                button.frame = frames[index]
                button.isHidden = false
            } else {
                button.isHidden = true
            }
        }
    }

    @objc private func keyClicked(_ sender: NSButton) { onKey?(sender) }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.chrome).cgColor
        // Nothing of the page draws outside the tab. WebKit paints a resize
        // a frame or two late: when the sidebar opens, the page moves right
        // and narrows at once, and for those frames the OLD, wider picture
        // sat at the new origin — its right edge spilled past the tab and
        // jumped back (the user: "ขอบเว็บทางขวากระตุก"). Clipped, the late
        // frames are cut at the tab's edge instead. (macOS 14+ views no
        // longer clip by default.)
        clipsToBounds = true
        layer?.masksToBounds = true
        addSubview(webView)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: WebBarView.height)
        webView.frame = CGRect(x: 0, y: WebBarView.height, width: bounds.width,
                               height: max(0, bounds.height - WebBarView.height))
        for case let overlay as ConnectionOverlayView in subviews { overlay.frame = bounds }
        onLayout?()
    }
}

/// The slim bar above the page: icon buttons (back, forward, reload/stop),
/// the URL field, Fill Login (key) and Open in Default Browser. A find field
/// appears only while ⌘F is in use; a short notice only while there is one.
final class WebBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 30

    weak var controller: WebTabController?

    private let back = WebBarView.button("chevron.left", "Back (⌘[)")
    private let forward = WebBarView.button("chevron.right", "Forward (⌘])")
    private let reload = WebBarView.button("arrow.clockwise", "Reload (⌘R)")
    private let external = WebBarView.button("arrow.up.right.square", "Open in Default Browser")
    private let urlField = NSTextField()
    /// The URL field (an empty tab's keyboard target).
    var locationField: NSView { urlField }
    private let findField = NSSearchField()
    private let noticeLabel = NSTextField(labelWithString: "")
    private var noticeGeneration = 0
    /// Save login's question (5.0 (23)): a line and two small buttons in
    /// the URL field's right end, in place of a notice — never a dialog.
    private let promptLabel = NSTextField(labelWithString: "")
    private let promptYes = NSButton(title: "Save", target: nil, action: nil)
    private let promptNo = NSButton(title: "Not Now", target: nil, action: nil)
    private var promptAnswer: ((Bool) -> Void)?
    private var promptGeneration = 0
    private var promptShown: Bool { !promptLabel.isHidden }
    private var queuedNotice: String?
    private var findShown = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.chrome).cgColor
        for (button, action) in [(back, #selector(goBack)), (forward, #selector(goForward)), (reload, #selector(reloadOrStop)),
                                 (external, #selector(openExternal))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.focusRingType = .none
        urlField.font = .systemFont(ofSize: 12)
        urlField.textColor = NSColor(Theme.tabText)
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false
        urlField.placeholderString = "Search or enter address"
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlEntered)
        urlField.wantsLayer = true
        let fieldBack = NSView()
        fieldBack.wantsLayer = true
        fieldBack.layer?.backgroundColor = NSColor(Theme.tabActive).cgColor
        fieldBack.layer?.cornerRadius = 6
        fieldBack.identifier = NSUserInterfaceItemIdentifier("urlBack")
        addSubview(fieldBack)
        addSubview(urlField)
        findField.font = .systemFont(ofSize: 12)
        findField.controlSize = .small
        findField.placeholderString = "Find"
        findField.sendsSearchStringImmediately = false
        findField.target = self
        findField.action = #selector(findEntered)
        findField.delegate = self
        findField.isHidden = true
        addSubview(findField)
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = SheepAlert.cautionYellow
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.isHidden = true
        addSubview(noticeLabel)
        promptLabel.font = .systemFont(ofSize: 11, weight: .medium)
        promptLabel.textColor = NSColor(Theme.tabText)
        promptLabel.lineBreakMode = .byTruncatingTail
        for (button, action) in [(promptYes, #selector(promptSaid(_:))), (promptNo, #selector(promptSaid(_:)))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.refusesFirstResponder = true
            button.target = self
            button.action = action
            button.isHidden = true
            addSubview(button)
        }
        promptLabel.isHidden = true
        addSubview(promptLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static func button(_ symbol: String, _ help: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(Theme.dimText)
        // No hover tooltip (the user's rule for icon buttons); VoiceOver
        // still gets the name.
        button.setAccessibilityLabel(help)
        return button
    }

    override func layout() {
        super.layout()
        let h = Self.height
        let size: CGFloat = 24
        var x: CGFloat = 8
        for button in [back, forward, reload] {
            button.frame = CGRect(x: x, y: (h - size) / 2, width: size, height: size)
            x += size + 2
        }
        var right = bounds.width - 8
        for button in [external] {
            right -= size
            button.frame = CGRect(x: right, y: (h - size) / 2, width: size, height: size)
            right -= 2
        }
        right -= 4
        if findShown {
            let width: CGFloat = 170
            findField.frame = CGRect(x: right - width, y: (h - 22) / 2, width: width, height: 22)
            right -= width + 6
        }
        let fieldX = x + 6
        let fieldWidth = max(40, right - fieldX)
        let fieldBack = subviews.first { $0.identifier?.rawValue == "urlBack" }
        fieldBack?.frame = CGRect(x: fieldX, y: 4, width: fieldWidth, height: h - 8)
        let textHeight = urlField.intrinsicContentSize.height
        if promptShown {
            promptLabel.sizeToFit()
            promptYes.sizeToFit()
            promptNo.sizeToFit()
            let buttons = promptYes.frame.width + promptNo.frame.width + 4
            let labelWidth = min(promptLabel.frame.width, max(60, fieldWidth * 0.7 - buttons - 8))
            let width = labelWidth + 8 + buttons
            var px = fieldX + fieldWidth - width - 4
            promptLabel.frame = CGRect(x: px, y: (h - promptLabel.frame.height) / 2, width: labelWidth, height: promptLabel.frame.height)
            px += labelWidth + 8
            promptNo.frame = CGRect(x: px, y: (h - promptNo.frame.height) / 2, width: promptNo.frame.width, height: promptNo.frame.height)
            px += promptNo.frame.width + 4
            promptYes.frame = CGRect(x: px, y: (h - promptYes.frame.height) / 2, width: promptYes.frame.width, height: promptYes.frame.height)
            let textWidth = WebBarGeometry.urlTextWidth(fieldWidth: fieldWidth, noticeWidth: width)
            urlField.frame = CGRect(x: fieldX + 8, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
            noticeLabel.frame = .zero
            return
        }
        noticeLabel.sizeToFit()
        let noticeWidth = min(noticeLabel.frame.width, fieldWidth * 0.6)
        // The URL text stops where a shown notice starts (it used to run under it).
        let textWidth = WebBarGeometry.urlTextWidth(fieldWidth: fieldWidth, noticeWidth: noticeLabel.isHidden ? nil : noticeWidth)
        urlField.frame = CGRect(x: fieldX + 8, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        noticeLabel.frame = CGRect(x: fieldX + fieldWidth - noticeWidth - 8, y: (h - noticeLabel.frame.height) / 2,
                                   width: noticeWidth, height: noticeLabel.frame.height)
    }

    /// Buttons and the field follow the page.
    func refresh() {
        guard let controller else { return }
        let web = controller.webView
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        let symbol = web.isLoading ? "xmark" : "arrow.clockwise"
        reload.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        reload.setAccessibilityLabel(web.isLoading ? "Stop" : "Reload")
        reload.isEnabled = !controller.isEmpty
        external.isEnabled = WebAddress.isLoadable(controller.webView.url ?? URL(string: controller.host.address))
        for button in [back, forward, reload, external] {
            button.contentTintColor = NSColor(button.isEnabled ? Theme.tabText : Theme.dimText).withAlphaComponent(button.isEnabled ? 0.85 : 0.4)
        }
        if urlField.currentEditor() == nil {
            urlField.stringValue = WebAddress.displayURL(controller.webView.url?.absoluteString ?? controller.host.address)
        }
    }

    /// A short line at the right of the URL field, gone after a few seconds.
    func notice(_ text: String) {
        // A question is up: it keeps the place; the notice shows after it.
        if promptShown { queuedNotice = text; return }
        noticeGeneration &+= 1
        let generation = noticeGeneration
        noticeLabel.stringValue = text
        noticeLabel.isHidden = false
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeLabel.isHidden = true
            self.needsLayout = true
        }
    }

    /// Save login's question: `answer(true)` = the action, `false` = Not Now.
    /// A newer question replaces it (unanswered); it goes by itself after a
    /// minute, unanswered — the password it holds goes with it.
    func ask(_ text: String, action: String, answer: @escaping (Bool) -> Void) {
        promptGeneration &+= 1
        let generation = promptGeneration
        promptAnswer = answer
        promptLabel.stringValue = text
        promptYes.title = action
        for view in [promptLabel, promptYes, promptNo] as [NSView] { view.isHidden = false }
        noticeLabel.isHidden = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.promptGeneration == generation else { return }
            self.hidePrompt()
        }
    }

    func hidePrompt() {
        promptGeneration &+= 1
        promptAnswer = nil
        for view in [promptLabel, promptYes, promptNo] as [NSView] { view.isHidden = true }
        needsLayout = true
        if let text = queuedNotice {
            queuedNotice = nil
            notice(text)
        }
    }

    @objc private func promptSaid(_ sender: NSButton) {
        let answer = promptAnswer
        hidePrompt()
        answer?(sender === promptYes)
    }

    func focusLocation() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    func showFind() {
        findShown = true
        findField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    func hideFind() {
        guard findShown else { return }
        findShown = false
        findField.isHidden = true
        needsLayout = true
    }

    func find(backwards: Bool) {
        guard let controller else { return }
        let text = findField.stringValue
        guard !text.isEmpty else { showFind(); return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        controller.webView.find(text, configuration: configuration) { [weak self] result in
            if !result.matchFound { self?.notice("Not found") ; NSSound.beep() }
        }
    }

    @objc private func goBack() { controller?.goBack() }
    @objc private func goForward() { controller?.goForward() }
    @objc private func reloadOrStop() { controller?.reloadOrStop() }
    @objc private func openExternal() { controller?.openInDefaultBrowser() }

    @objc private func urlEntered() {
        controller?.load(typed: urlField.stringValue)
    }

    @objc private func findEntered() {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        find(backwards: shift)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        controller?.onFocus?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === urlField { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if control === findField {
            hideFind()
            if let web = controller?.webView { window?.makeFirstResponder(web) }
            return true
        }
        if control === urlField {
            urlField.stringValue = WebAddress.displayURL(controller?.webView.url?.absoluteString ?? controller?.host.address ?? "")
            if let controller, !controller.isEmpty { window?.makeFirstResponder(controller.webView) }
            return true
        }
        return false
    }
}

/// Hands `WebLoginKey.script`'s messages to the tab without the content
/// controller holding the tab (it retains its handlers).
final class WebLoginMessageProxy: NSObject, WKScriptMessageHandler {
    weak var controller: WebTabController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { controller?.loginMessage(message) }
    }
}
