import AppKit

// The in-app updater's AppKit half: scheduling, the network, the alerts, the
// download → verify → unpack → inspect → codesign chain, and handing the swap
// to the helper script. GENERIC: it knows the app only through `UpdateConfig`
// and `UpdateHooks` (built in the app's own file — SheepTermUpdate.swift
// here), so another Sheep app adopts it by copying this folder. The pure
// decisions it makes live in UpdateCore.swift and are harness-tested there.

/// One button of an updater alert.
struct UpdateAlertButton {
    enum Role { case primary, normal, cancel }
    var title: String
    var role: Role = .normal
}

/// Draws the updater's alerts in the app's own style. Returns the index of
/// the pressed button (in the order given).
@MainActor
protocol UpdateAlertPresenting {
    func present(title: String, message: String, accessory: NSView?, buttons: [UpdateAlertButton]) -> Int
}

/// Plain NSAlert, for an app without a house style.
struct NSAlertUpdatePresenter: UpdateAlertPresenting {
    func present(title: String, message: String, accessory: NSView?, buttons: [UpdateAlertButton]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        for button in buttons { alert.addButton(withTitle: button.title) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}

/// What the updater needs from the app around it.
struct UpdateHooks {
    /// Asked right before Install & Relaunch quits the app (live sessions,
    /// unsaved work …). false = the user cancelled; nothing is installed.
    var confirmBeforeQuit: @MainActor () -> Bool = { true }
    /// Runs just before `NSApp.terminate` (e.g. tell the app's quit guard
    /// the question was already answered). The app's normal quit path —
    /// log flushing included — still runs inside terminate.
    var prepareForQuit: @MainActor () -> Void = {}
    var presenter: any UpdateAlertPresenting = NSAlertUpdatePresenter()
}

@MainActor
final class Updater {
    let config: UpdateConfig
    let hooks: UpdateHooks

    private var inFlight = false
    /// A manual check pressed while an automatic one was already running:
    /// that one's result is then reported as a manual one would be.
    private var manualWaiting = false
    private var installing = false
    private var lastAutoCheck: Date?
    private var launchTimer: Timer?
    private var tickTimer: Timer?
    /// An automatic offer that arrived while another modal was up.
    private var deferredOffer: (UpdateOffer, UpdateVersion)?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    init(config: UpdateConfig, hooks: UpdateHooks) {
        self.config = config
        self.hooks = hooks
    }

    static var automaticChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: UpdateCore.autoCheckKey) as? Bool ?? true
    }

    // MARK: Scheduling

    /// Call once at launch: the first automatic check runs
    /// `UpdateCore.launchDelay` later, then every `checkInterval` while the
    /// app stays open. A coarse tick re-evaluates (a long Timer does not
    /// count time asleep), so turning the setting on later also works.
    func start() {
        guard launchTimer == nil, tickTimer == nil else { return }
        launchTimer = Timer.scheduledTimer(withTimeInterval: UpdateCore.launchDelay, repeats: false) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    /// A deferred offer is retried every `deferredRetryDelay` until no modal
    /// is up; this does not touch the background check schedule.
    private var deferredTimer: Timer?
    private func scheduleDeferredRetry() {
        deferredTimer?.invalidate()
        deferredTimer = Timer.scheduledTimer(withTimeInterval: UpdateCore.deferredRetryDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.deferredTimer = nil
                guard let deferred = self.deferredOffer else { return }
                if Self.modalIsUp { self.scheduleDeferredRetry(); return }
                self.deferredOffer = nil
                self.presentOffer(deferred.0, current: deferred.1, manual: false)
            }
        }
    }

    private func tick() {
        if let deferred = deferredOffer, !Self.modalIsUp {
            deferredOffer = nil
            presentOffer(deferred.0, current: deferred.1, manual: false)
            return
        }
        guard let delay = UpdateCore.nextAutoCheckDelay(enabled: Self.automaticChecksEnabled,
                                                        inFlight: inFlight || installing,
                                                        lastCheckThisRun: lastAutoCheck, now: Date())
        else { return }
        if lastAutoCheck == nil || delay <= 0 { check(manual: false) }
    }

    private static var modalIsUp: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    // MARK: Checking

    /// The menu item: always checks, ignores Skip, reports "up to date".
    func checkNow() { check(manual: true) }

    private func check(manual: Bool) {
        if installing { return }
        if inFlight {
            if manual { manualWaiting = true }
            return
        }
        inFlight = true
        if !manual { lastAutoCheck = Date() }
        Task {
            let result: Result<GitHubRelease, UpdateError>
            do { result = .success(try await fetchLatest()) }
            catch let error as UpdateError { result = .failure(error) }
            catch { result = .failure(.badStatus(-1)) }
            let reportAsManual = manual || manualWaiting
            inFlight = false
            manualWaiting = false
            handle(result, manual: reportAsManual)
        }
    }

    private func fetchLatest() async throws -> GitHubRelease {
        var request = URLRequest(url: config.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await capped(request, maxBytes: UpdateCore.maxReleaseJSONBytes) }
        catch let error as UpdateError { throw error }
        catch { throw UpdateError.notInstallable(String(localized: "Could not reach GitHub. Check the internet connection.") + "\n\n\(error.localizedDescription)") }
        if let http = response as? HTTPURLResponse, let error = UpdateCore.statusError(http.statusCode) {
            throw error
        }
        return try UpdateCore.decodeRelease(data)
    }

    private var currentVersion: UpdateVersion? {
        let info = Bundle.main.infoDictionary
        return UpdateCore.currentVersion(shortVersion: info?["CFBundleShortVersionString"] as? String,
                                         bundleVersion: info?["CFBundleVersion"] as? String,
                                         scheme: config.tagScheme)
    }

    private func handle(_ result: Result<GitHubRelease, UpdateError>, manual: Bool) {
        let release: GitHubRelease
        switch result {
        case .failure(let error):
            if manual { showError(String(localized: "Could Not Check for Updates"), error, page: nil) }
            return
        case .success(let value): release = value
        }
        guard let current = currentVersion else {
            if manual { showError(String(localized: "Could Not Check for Updates"), .notInstallable(String(localized: "This copy's own version cannot be read.")), page: nil) }
            return
        }
        let latest: UpdateVersion
        do { latest = try UpdateCore.version(of: release, config: config) }
        catch {
            if manual { showError(String(localized: "Could Not Check for Updates"), error, page: config.releasesPage) }
            return
        }
        let skipped = UserDefaults.standard.string(forKey: UpdateCore.skippedTagKey)
        switch UpdateCore.decide(latest: latest, current: current, skippedTag: skipped,
                                 manual: manual, scheme: config.tagScheme) {
        case .skipped:
            return
        case .upToDate:
            if manual {
                _ = hooks.presenter.present(
                    title: String(localized: "You're up to date"),
                    message: String(localized: "\(config.appName) \(current.description) is the latest version."),
                    accessory: nil, buttons: [UpdateAlertButton(title: String(localized: "OK"), role: .primary)])
            }
        case .offer:
            do {
                let offer = try UpdateCore.offer(from: release, config: config)
                if !manual, Self.modalIsUp {
                    deferredOffer = (offer, current)
                    scheduleDeferredRetry()
                    return
                }
                presentOffer(offer, current: current, manual: manual)
            } catch {
                presentUnverifiable(release: release, latest: latest, current: current, error: error)
            }
        }
    }

    // MARK: Alerts

    private func presentOffer(_ offer: UpdateOffer, current: UpdateVersion, manual: Bool) {
        // Short first page; the release notes only behind Details… (5.0 (4)).
        let page = UpdateOfferAction.offerPage(hasNotes: !offer.notes.isEmpty)
        while true {
            let answer = hooks.presenter.present(
                title: String(localized: "\(config.appName) \(offer.version.description) is available"),
                message: String(localized: "You have \(current.description)."),
                accessory: nil,
                buttons: Self.buttons(page))
            switch UpdateOfferAction.answer(answer, on: page) {
            case .install: install(offer, current: current); return
            case .skip: UserDefaults.standard.set(offer.tag, forKey: UpdateCore.skippedTagKey); return
            case .later, .back: return
            case .details:
                let details = UpdateOfferAction.detailsPage
                let choice = hooks.presenter.present(
                    title: String(localized: "What's new in \(config.appName) \(offer.version.description)"),
                    message: String(localized: "You have \(current.description)."),
                    accessory: Self.notesView(offer.notes),
                    buttons: Self.buttons(details))
                if UpdateOfferAction.answer(choice, on: details) == .install {
                    install(offer, current: current)
                    return
                }
                // Back: the first page again.
            }
        }
    }

    private static func buttons(_ page: [UpdateOfferAction]) -> [UpdateAlertButton] {
        page.map { UpdateAlertButton(title: $0.title, role: $0 == .install ? .primary : .normal) }
    }

    /// A newer release that cannot be verified (no .sig, wrong asset, a URL
    /// outside the repository): never installed, the page offered instead.
    private func presentUnverifiable(release: GitHubRelease, latest: UpdateVersion,
                                     current: UpdateVersion, error: UpdateError) {
        let answer = hooks.presenter.present(
            title: String(localized: "\(config.appName) \(latest.description) is available"),
            message: String(localized: "You have \(current.description). It cannot be installed from here: \(error.message)"),
            accessory: nil,
            buttons: [UpdateAlertButton(title: String(localized: "Open Release Page"), role: .primary),
                      UpdateAlertButton(title: String(localized: "Later")),
                      UpdateAlertButton(title: String(localized: "Skip This Version"))])
        switch answer {
        case 0: NSWorkspace.shared.open(UpdateCore.releasePage(release.htmlURL, config: config))
        case 2: UserDefaults.standard.set(release.tagName, forKey: UpdateCore.skippedTagKey)
        default: break
        }
    }

    private func showError(_ title: String, _ error: UpdateError, page: URL?) {
        if let page {
            let answer = hooks.presenter.present(
                title: title, message: error.message, accessory: nil,
                buttons: [UpdateAlertButton(title: String(localized: "Open Release Page"), role: .primary),
                          UpdateAlertButton(title: String(localized: "Close"))])
            if answer == 0 { NSWorkspace.shared.open(page) }
        } else {
            _ = hooks.presenter.present(title: title, message: error.message, accessory: nil,
                                        buttons: [UpdateAlertButton(title: String(localized: "OK"), role: .primary)])
        }
    }

    /// The release notes: plain text, selectable, scrollable, fixed size.
    /// The Details page: the release notes as a readable list — a bullet
    /// per item with a hanging indent, body-size text in the label colour,
    /// as tall as the notes up to `notesMaxHeight`, scrolling beyond.
    static let notesWidth: CGFloat = 288
    static let notesMaxHeight: CGFloat = 280

    static func notesView(_ text: String) -> NSView {
        let body = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12.5)
        let indent: CGFloat = 14
        for (index, item) in UpdateCore.noteItems(text).enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = index == 0 ? 0 : 7
            paragraph.lineSpacing = 1.5
            if item.bullet {
                paragraph.headIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                paragraph.defaultTabInterval = indent
            }
            let line = (index == 0 ? "" : "\n") + (item.bullet ? "•\t" : "") + item.text
            body.append(NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        let inset = NSSize(width: 10, height: 10)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: notesWidth, height: 10))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(body)
        // Fit the notes; cap and scroll when they are long.
        var height = notesMaxHeight
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            height = min(notesMaxHeight, ceil(layout.usedRect(for: container).height + inset.height * 2))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: notesWidth, height: max(height, 44)))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.frame.size.height = scroll.frame.height
        scroll.documentView = textView
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        return scroll
    }

    // MARK: Installing

    private func install(_ offer: UpdateOffer, current: UpdateVersion) {
        guard !installing else { return }
        installing = true
        let progress = UpdateProgressPanel(title: String(localized: "Downloading \(config.appName) \(offer.version.description)…"))
        let task = Task { () -> Void in
            defer { installing = false; progress.close() }
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(config.appName)-update-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let app = try await downloadAndVerify(offer, current: current, into: work, progress: progress)
                progress.close()
                finishInstall(app: app, zip: work.appendingPathComponent(offer.zipName), work: work, offer: offer)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: work)
            } catch {
                try? FileManager.default.removeItem(at: work)
                progress.close()
                let failure = error as? UpdateError ?? .notInstallable(String(localized: "The download failed: \(error.localizedDescription)"))
                showError(String(localized: "The update was not installed"), failure, page: offer.page)
            }
        }
        progress.onCancel = { task.cancel() }
        progress.show()
    }

    private func downloadAndVerify(_ offer: UpdateOffer, current: UpdateVersion, into work: URL,
                                   progress: UpdateProgressPanel) async throws -> URL {
        // The signature first: small, and a release without one stops here.
        let sigData = try await fetch(offer.signatureURL, maxBytes: UpdateCore.maxSignatureBytes)
        try Task.checkCancellation()
        var request = URLRequest(url: offer.zipURL)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await UpdateDownloader.download(
            request, maxBytes: UpdateCore.maxZipBytes,
            progress: { got, total in
                Task { @MainActor in
                    progress.setProgress(got, of: total > 0 ? total : Int64(offer.zipSize))
                }
            })
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, let error = UpdateCore.statusError(http.statusCode) {
            throw error
        }
        let zipURL = work.appendingPathComponent(offer.zipName)
        try FileManager.default.moveItem(at: tmp, to: zipURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? -1
        guard size == offer.zipSize, size <= UpdateCore.maxZipBytes else {
            throw UpdateError.badArchive(String(localized: "its size (\(size) bytes) is not the \(offer.zipSize) the release lists"))
        }
        progress.setStatus(String(localized: "Verifying…"))
        // Verified BEFORE anything reads it as an archive.
        let zipData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        guard UpdateCore.verifySignature(of: zipData, signatureText: sigData,
                                         publicKeyBase64: config.publicKeyBase64) else {
            throw UpdateError.badSignature
        }
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path]) == 0 else {
            throw UpdateError.badArchive(String(localized: "it could not be unpacked"))
        }
        let app = try UpdateCore.inspectExtracted(at: extracted, config: config,
                                                  bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                                                  current: current, advertised: offer.version)
        // A Developer ID copy pins its own team and asks Gatekeeper (notarized); a self-signed / ad-hoc copy can
        // only check the seal.
        let team = CodeIdentity.ownTeamID
        guard await Self.run("/usr/bin/codesign", UpdateCore.codesignArguments(appPath: app.path, teamID: team)) == 0 else {
            throw UpdateError.badArchive(String(localized: "its code signature does not verify"))
        }
        if let gatekeeper = UpdateCore.gatekeeperArguments(appPath: app.path, teamID: team) {
            guard await Self.run("/usr/sbin/spctl", gatekeeper) == 0 else {
                throw UpdateError.badArchive(String(localized: "Gatekeeper does not accept it (not notarized)"))
            }
        }
        try Task.checkCancellation()
        return app
    }

    private func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await capped(request, maxBytes: maxBytes)
        if let http = response as? HTTPURLResponse, let error = UpdateCore.statusError(http.statusCode) {
            throw error
        }
        return data
    }

    /// A small body read with a hard cap WHILE it streams: stops at the cap
    /// instead of buffering whatever the server sends.
    private func capped(_ request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let name = request.url?.lastPathComponent ?? "response"
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maxBytes) { throw UpdateError.tooLarge(name) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw UpdateError.tooLarge(name) }
        }
        return (data, response)
    }

    /// A tool's exit status, waited for off the main thread.
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    private func finishInstall(app: URL, zip: URL, work: URL, offer: UpdateOffer) {
        guard let target = UpdateCore.installTarget(bundleURL: Bundle.main.bundleURL) else {
            revealVerifiedZip(zip, work: work, offer: offer)
            return
        }
        guard hooks.confirmBeforeQuit() else {
            try? FileManager.default.removeItem(at: work)
            return
        }
        let script = work.appendingPathComponent("install.sh")
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appendingPathComponent("\(config.appName)-update.log")
        let stamp = String(Int(Date().timeIntervalSince1970))
        do {
            try Data(UpdateCore.helperScript.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path,
                                 String(ProcessInfo.processInfo.processIdentifier),
                                 target.path, app.path,
                                 UpdateCore.backupPath(for: target, stamp: stamp),
                                 work.path, log.path]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            showError(String(localized: "The update was not installed"),
                      .notInstallable(String(localized: "The installer could not be started: \(error.localizedDescription)")),
                      page: offer.page)
            return
        }
        hooks.prepareForQuit()
        NSApp.terminate(nil)
    }

    /// Not in a writable /Applications: the verified zip goes to Downloads
    /// and is shown in Finder; the user installs it by hand.
    private func revealVerifiedZip(_ zip: URL, work: URL, offer: UpdateOffer) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (offer.zipName as NSString).deletingPathExtension
        var destination = downloads.appendingPathComponent(offer.zipName)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent("\(base) \(n).zip")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: zip, to: destination)
        } catch {
            destination = zip
        }
        if destination != zip { try? FileManager.default.removeItem(at: work) }
        _ = hooks.presenter.present(
            title: String(localized: "Update downloaded"),
            message: String(localized: "\(config.appName) can only replace itself when it runs from the Applications folder and that folder is writable. The verified \(offer.zipName) is in Finder: unzip it and move \(config.appName).app into Applications."),
            accessory: nil, buttons: [UpdateAlertButton(title: String(localized: "Show in Finder"), role: .primary)])
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

/// A small floating panel while the update downloads: a bar and Cancel.
@MainActor
final class UpdateProgressPanel: NSObject {
    var onCancel: (() -> Void)?
    private let panel: NSPanel
    private let label: NSTextField
    private let bar: NSProgressIndicator
    private var closed = false

    init(title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancel = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        self.panel = panel
        self.label = label
        self.bar = bar
        super.init()
        cancel.target = self
        cancel.action = #selector(cancelPressed)
    }

    func show() {
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 110))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.orderFront(nil)
    }

    func setStatus(_ text: String) {
        label.stringValue = text
        if text == String(localized: "Verifying…") { bar.isIndeterminate = true; bar.startAnimation(nil) }
    }

    /// Determinate "x of y MB" once the download reports its size.
    func setProgress(_ got: Int64, of total: Int64) {
        guard !closed else { return }
        if total > 0 {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1 }
            bar.doubleValue = min(1, Double(got) / Double(total))
        }
        label.stringValue = String(localized: "Downloading… \(UpdateCore.megabytes(got, of: total))")
    }

    func close() {
        guard !closed else { return }
        closed = true
        panel.orderOut(nil)
    }

    @objc private func cancelPressed() {
        onCancel?()
        close()
    }
}

/// The zip download: a delegate task so the byte count is seen WHILE it
/// streams and the transfer is cut off past `maxBytes`, instead of after the
/// whole file landed. The finished file is moved out of the session's temp
/// location inside the delegate callback (it is deleted when it returns).
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var tooBig = false
    private var moved: URL?

    private init(maxBytes: Int, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.maxBytes = maxBytes
        self.progress = progress
    }

    static func download(_ request: URLRequest, maxBytes: Int,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let worker = UpdateDownloader(maxBytes: maxBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: worker, delegateQueue: nil)
        worker.session = session
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(URL, URLResponse), Error>) in
                worker.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if UpdateCore.exceedsCap(received: totalBytesWritten, max: maxBytes)
            || UpdateCore.exceedsCap(received: totalBytesExpectedToWrite, max: maxBytes) {
            tooBig = true
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: location, to: keep); moved = keep } catch { moved = nil }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); continuation = nil }
        if tooBig {
            continuation?.resume(throwing: UpdateError.tooLarge(String(localized: "the update")))
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let moved, let response = task.response {
            continuation?.resume(returning: (moved, response))
        } else {
            continuation?.resume(throwing: UpdateError.notInstallable(String(localized: "The download could not be saved.")))
        }
    }
}
