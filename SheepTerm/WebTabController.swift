import AppKit
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
/// - No `WKScriptMessageHandler`: pages can call nothing in the app.
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
        webView = SheepWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 480), configuration: configuration)
        view = WebTabView(webView: webView)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.onFocus = { [weak self] in self?.onFocus?() }
        webView.isHidden = host.address.isEmpty
        view.bar.controller = self
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

    /// The login this host saved: the credential's user wins over the host's
    /// own field (the SSH rule), the password comes from the Keychain vault.
    private var savedLogin: (username: String, credential: Credential?) {
        let live = liveHost
        let credential = live.credentialID.flatMap { AppModel.shared.credentialStore.credential(for: $0) }
        if let credential, !credential.username.isEmpty { return (credential.username, credential) }
        return (live.username, credential)
    }

    var canFillLogin: Bool {
        let login = savedLogin
        return !login.username.isEmpty || login.credential != nil
    }

    /// Button only. Checks the page's origin against the saved URL first,
    /// then fills the first visible password field (and the user field before
    /// it) with the values passed as arguments — never spliced into script,
    /// never submitted.
    func fillLogin() {
        let login = savedLogin
        let savedURL = liveHost.address
        let password = login.credential.flatMap { AppModel.shared.credentialStore.password(for: $0) } ?? ""
        if let refusal = WebFillLogin.check(pageURL: webView.url?.absoluteString, savedURL: savedURL,
                                            username: login.username, hasPassword: !password.isEmpty,
                                            provisional: WebFillLogin.isProvisional(currentURL: webView.url?.absoluteString,
                                                                                    committedURL: committedURL)) {
            view.bar.notice(refusal.message)
            NSSound.beep()
            return
        }
        // The document itself is checked too (`expected`): `webView.url` can
        // name a page that is not the one on screen yet.
        guard let expected = WebFillLogin.expectedOrigin(savedURL: savedURL) else {
            view.bar.notice(WebFillLogin.Refusal.otherOrigin.message)
            return
        }
        webView.callAsyncJavaScript(WebFillLogin.script,
                                    arguments: ["user": login.username, "pass": password, "expected": expected],
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
        guard WebFramePolicy.allows(navigationAction.request.url, mainFrame: isMain) else {
            if isMain { view.bar.notice("Only http:// and https:// open in a web tab") }
            return (.cancel, preferences)
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

/// The tab's view: the bar on top, the page under it.
final class WebTabView: NSView {
    let bar = WebBarView()
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.chrome).cgColor
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
    private let fill = WebBarView.button("key", "Fill Login — the saved username and password, into this page (never submitted)")
    private let external = WebBarView.button("arrow.up.right.square", "Open in Default Browser")
    private let urlField = NSTextField()
    /// The URL field (an empty tab's keyboard target).
    var locationField: NSView { urlField }
    private let findField = NSSearchField()
    private let noticeLabel = NSTextField(labelWithString: "")
    private var noticeGeneration = 0
    private var findShown = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.chrome).cgColor
        for (button, action) in [(back, #selector(goBack)), (forward, #selector(goForward)), (reload, #selector(reloadOrStop)),
                                 (fill, #selector(fillLogin)), (external, #selector(openExternal))] {
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
        for button in [external, fill] {
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
        fill.isEnabled = controller.canFillLogin
        external.isEnabled = WebAddress.isLoadable(controller.webView.url ?? URL(string: controller.host.address))
        for button in [back, forward, reload, fill, external] {
            button.contentTintColor = NSColor(button.isEnabled ? Theme.tabText : Theme.dimText).withAlphaComponent(button.isEnabled ? 0.85 : 0.4)
        }
        if urlField.currentEditor() == nil {
            urlField.stringValue = WebAddress.displayURL(controller.webView.url?.absoluteString ?? controller.host.address)
        }
    }

    /// A short line at the right of the URL field, gone after a few seconds.
    func notice(_ text: String) {
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
    @objc private func fillLogin() { controller?.fillLogin() }
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
