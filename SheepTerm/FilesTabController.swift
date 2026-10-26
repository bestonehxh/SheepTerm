import AppKit
import Combine
import SwiftUI

/// A Files tab (SFTP / SCP / FTP / TFTP): this Mac on the left, the device
/// on the right. Owns one `RemoteFileClient`; every remote call goes
/// through it on the engine's own queue — main only sees results.
@MainActor
final class FilesTabController: ObservableObject {
    typealias Phase = FilesPlan.Phase

    struct Transfer: Identifiable, Equatable {
        enum State: Equatable { case queued, active, done, failed(String), cancelled }
        let id = UUID()
        let name: String
        let isUpload: Bool
        var done: Int64 = 0
        var total: Int64?
        var state: State = .queued
    }

    struct LocalEntry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var phase: Phase = .connecting {
        didSet { refreshCard() }
    }
    @Published private(set) var canBrowse = true
    @Published private(set) var remotePath = "/"
    /// The login directory (`~` in the address bar), read once on connect.
    private var remoteHome = "/"
    @Published private(set) var remoteEntries: [RemoteEntry] = []
    @Published private(set) var remoteBusy = false
    @Published private(set) var localPath: URL
    @Published private(set) var localEntries: [LocalEntry] = []
    @Published private(set) var transfers: [Transfer] = []
    @Published var notice: String?

    private(set) var endpoint: RemoteEndpoint
    let title: String
    private var client: RemoteFileClient?
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var queueTail: Task<Void, Never>?
    private var closed = false
    /// Bumped by every connect: a result from an older attempt is dropped
    /// (Reconnect while connecting must not let the first one's late
    /// failure cover the live session).
    private var generation = 0

    /// An SSH tab of this host lending its connection (SFTP as a second
    /// channel there). Asked at every connect; nil = connect on our own.
    var sharedSession: (() -> SSHChannelBridge?)?
    /// The host is behind a jump host: never dial it directly — only a
    /// lent connection (which already goes through the bastion) is used.
    var reachedThroughJump = false
    /// True while the session rides a terminal tab's connection.
    @Published private(set) var ridesTerminal = false

    var onTitleChange: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFocus: (() -> Void)?
    /// Close on the card's failure page: the tab goes.
    var onCloseTab: (() -> Void)?

    /// The SSH tab's connection card (`ConnectionCardView`), shown by
    /// `FilesTabView` while the phase is not `.connected`: one card, one
    /// look, for every session that connects.
    private(set) lazy var card: ConnectionCardView = {
        let label = FilesPlan.protocolLabel(endpoint.proto, canBrowse: true)
        let address = "\(endpoint.host):\(endpoint.port)"
        let card = ConnectionCardView(header: ConnectionCardHeader(title: title, subtitle: "\(label) \(address)",
                                                                   windowTitle: "\(title) — \(address)"))
        card.model.filesTrack = FilesPlan.cardNodes(endpoint.proto)
        card.onFocus = { [weak self] in self?.onFocus?() }
        return card
    }()
    /// A username typed on the card, waiting for its password.
    private var pendingUser = ""

    private(set) lazy var hosting: NSHostingView<AnyView> = {
        let view = NSHostingView(rootView: AnyView(FilesTabView().environmentObject(self)))
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    private static let localKey = "filesTabLocalFolder"

    init(endpoint: RemoteEndpoint, title: String) {
        self.endpoint = endpoint
        self.title = title
        let saved = UserDefaults.standard.string(forKey: Self.localKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        localPath = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? downloads
    }

    var protocolLabel: String { FilesPlan.protocolLabel(endpoint.proto, canBrowse: canBrowse) }

    // MARK: Connect

    func start() {
        refreshLocal()
        connect()
        // Mouse-down anywhere in this pane → onFocus (SwiftUI's Table eats a
        // tap gesture, so it is watched at the event level, this window only).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.hosting.window, event.window === window else { return event }
            let point = self.hosting.convert(event.locationInWindow, from: nil)
            if self.hosting.bounds.contains(point) { self.onFocus?() }
            return event
        }
    }

    private var clickMonitor: Any?

    func connect() {
        guard !closed else { return }
        generation += 1
        let attempt = generation
        // The old session goes now, transfers with it.
        transferTasks.values.forEach { $0.cancel() }
        client?.close()
        client = nil
        pendingUser = ""
        phase = .connecting
        onStatus?(String(localized: "connecting to \(endpoint.host)…"))
        let endpoint = self.endpoint
        let bridge = endpoint.proto == .sftp || endpoint.proto == .scp ? sharedSession?() : nil
        let jumpOnly = reachedThroughJump
        ridesTerminal = false
        Task {
            do {
                let client: RemoteFileClient
                var riding = false
                switch endpoint.proto {
                case .sftp, .scp:
                    (client, riding) = try await SFTPClient.connect(endpoint, preferring: bridge, jumpOnly: jumpOnly)
                case .ftp: client = try await FTPClient.connect(endpoint)
                case .tftp: client = try await TFTPClient.connect(endpoint)
                }
                guard !closed, attempt == generation else { client.close(); return }
                self.client = client
                canBrowse = client.canBrowse
                ridesTerminal = riding
                phase = .connected
                var status = "\(protocolLabel) · \(endpoint.username.isEmpty ? "" : endpoint.username + "@")\(endpoint.host)"
                if riding { status += String(localized: " · via SSH tab") }
                onStatus?(status)
                if canBrowse {
                    let home = FilesPlan.normalize((try? await client.home()) ?? "/")
                    remoteHome = home
                    await list(home)
                }
            } catch let error as RemoteFileError {
                guard attempt == generation else { return }
                handle(connectError: error)
            } catch {
                guard attempt == generation else { return }
                handle(connectError: .connection(String(describing: error)))
            }
        }
    }

    private func handle(connectError error: RemoteFileError) {
        guard !closed else { return }
        switch error {
        case .hostKeyUnknown(let fp, let type):
            phase = .hostKey(fingerprint: fp, keyType: type, changed: false)
        case .hostKeyChanged(let fp, let type):
            phase = .hostKey(fingerprint: fp, keyType: type, changed: true)
        case .passwordRequired:
            phase = .login(failed: false)
        case .authenticationFailed:
            phase = .login(failed: endpoint.password != nil)
        default:
            phase = .failed(error.description)
        }
    }

    func answerHostKey(_ decision: HostKeyDecision?) {
        guard let decision else {
            phase = .failed(String(localized: "Host key not trusted"))
            return
        }
        endpoint.hostKey = decision
        connect()
    }

    func submitLogin(username: String, password: String) {
        if !username.isEmpty { endpoint.username = username }
        endpoint.password = password
        connect()
    }

    // MARK: Connection card

    /// Puts the phase on the card (the SSH card's pages and buttons).
    private func refreshCard() {
        let card = self.card
        switch phase {
        case .connected:
            return
        case .connecting:
            card.show(stage: .connect, page: .progress(String(localized: "Connecting…"))) { [weak self] _ in
                self?.cancelConnecting()
            }
        case .hostKey(let fingerprint, let keyType, let changed):
            let question = SSHWorker.HostKeyQuestion(host: endpoint.host, port: endpoint.port, keyType: keyType,
                                                     fingerprint: fingerprint, conflict: changed ? .changed : nil)
            card.show(stage: .hostKey, page: .question(prompt(.hostKey(question)))) { [weak self] action in
                guard case .answer(let reply) = action else { self?.answerHostKey(nil); return }
                switch reply {
                case .trust: self?.answerHostKey(.trustAndSave(fingerprint: fingerprint))
                case .trustOnce: self?.answerHostKey(.trustOnce(fingerprint: fingerprint))
                default: self?.answerHostKey(nil)
                }
            }
        case .login(let failed):
            let user = endpoint.username.isEmpty ? pendingUser : endpoint.username
            if FilesPlan.loginStage(knownUsername: user) == .user {
                card.show(stage: .user, page: .question(prompt(.username)),
                          busyCancel: { [weak self] in self?.cancelConnecting() }) { [weak self] action in
                    guard let self, case .answer(.text(let typed)) = action else { self?.cancelConnecting(); return }
                    self.pendingUser = typed
                    self.refreshCard()
                }
            } else {
                var question = prompt(.password(account: "\(user)@\(endpoint.host)"))
                question.rejected = failed
                card.show(stage: .password, page: .question(question),
                          busyCancel: { [weak self] in self?.cancelConnecting() }) { [weak self] action in
                    guard case .answer(.text(let password)) = action else { self?.cancelConnecting(); return }
                    self?.submitLogin(username: user, password: password)
                }
            }
        case .failed(let why):
            if FilesPlan.isDown(phase) { onStatus?(String(localized: "disconnected")) }
            let plan = ConnectionCardPlan.failure(at: card.stage, offersKnownHosts: false, offersTryAgain: true)
            card.show(stage: plan.stage, page: .failure(title: String(localized: "Connection failed"), message: why,
                                                        hostKeyProblem: false, plan: plan)) { [weak self] action in
                if case .tryAgain = action { self?.connect() } else { self?.onCloseTab?() }
            }
        }
    }

    private func prompt(_ step: ConnectionPrompt.Step) -> ConnectionPrompt {
        ConnectionPrompt(step: step, host: endpoint.host, viaJump: false, tabHost: endpoint.host, fallbackText: "")
    }

    /// Cancel / Esc while connecting or on a question: the attempt is dropped.
    private func cancelConnecting() {
        generation += 1
        client?.close()
        client = nil
        phase = .failed(String(localized: "cancelled"))
    }

    // MARK: Remote listing

    func list(_ path: String) async {
        guard let client, canBrowse else { return }
        let path = FilesPlan.normalize(path)
        remoteBusy = true
        defer { remoteBusy = false }
        do {
            let entries = try await client.list(path)
            remotePath = path
            remoteEntries = FilesPlan.sorted(entries)
            notice = nil
        } catch {
            notice = (error as? RemoteFileError)?.description ?? String(describing: error)
        }
    }

    func open(_ entry: RemoteEntry) {
        guard entry.isDirectory || entry.isSymlink else { download([entry]); return }
        Task { await list(FilesPlan.join(remotePath, entry.name)) }
    }

    var canGoUp: Bool { FilesPlan.canGoUp(remotePath) }
    func goUp() {
        guard canGoUp else { return }
        Task { await list(FilesPlan.parent(of: remotePath)) }
    }
    func refreshRemote() { Task { await list(remotePath) } }
    func goTo(_ typed: String) { Task { await list(FilesPlan.resolve(typed, from: remotePath, home: remoteHome)) } }

    func makeDirectory(_ raw: String) {
        guard let client, let name = FilesPlan.validName(raw) else { NSSound.beep(); return }
        let path = FilesPlan.join(remotePath, name)
        Task {
            do { try await client.makeDirectory(path); await list(remotePath) }
            catch { notice = (error as? RemoteFileError)?.description ?? String(describing: error) }
        }
    }

    func rename(_ entry: RemoteEntry, to raw: String) {
        guard let client, let name = FilesPlan.validName(raw), name != entry.name else { return }
        let from = FilesPlan.join(remotePath, entry.name), to = FilesPlan.join(remotePath, name)
        Task {
            do { try await client.rename(from, to: to); await list(remotePath) }
            catch { notice = (error as? RemoteFileError)?.description ?? String(describing: error) }
        }
    }

    func remove(_ entries: [RemoteEntry]) {
        guard let client, !entries.isEmpty else { return }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = entries.count == 1
            ? String(localized: "Delete “\(entries[0].name)” on \(endpoint.host)?")
            : String(localized: "Delete \(entries.count) items on \(endpoint.host)?")
        alert.informativeText = String(localized: "This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        guard alert.sheepStyled().runModal() == .alertSecondButtonReturn else { return }
        let dir = remotePath
        Task {
            for entry in entries {
                do { try await client.remove(FilesPlan.join(dir, entry.name), isDirectory: entry.isDirectory) }
                catch { notice = (error as? RemoteFileError)?.description ?? String(describing: error); break }
            }
            await list(dir)
        }
    }

    // MARK: Local side

    func refreshLocal() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: localPath, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        localEntries = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LocalEntry(url: url, isDirectory: values?.isDirectory ?? false,
                              size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func openLocal(_ entry: LocalEntry) {
        if entry.isDirectory { setLocalPath(entry.url) } else { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    var canGoUpLocal: Bool { localPath.standardizedFileURL.path != "/" }
    /// At "/" nothing: `deletingLastPathComponent()` on "/" gives "/..".
    func localUp() {
        guard canGoUpLocal else { return }
        setLocalPath(localPath.standardizedFileURL.deletingLastPathComponent())
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = localPath
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLocalPath(url)
    }

    /// Typed into the Mac side's address bar: absolute, `~`, `~/x`, or
    /// relative to the current folder (`..` works). A folder that is not
    /// there beeps and changes nothing.
    func openLocalPath(_ typed: String) {
        guard let url = FilesPlan.localFolder(typed, from: localPath, home: FileManager.default.homeDirectoryForCurrentUser) else {
            NSSound.beep(); return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { NSSound.beep(); return }
        setLocalPath(url)
    }

    private func setLocalPath(_ url: URL) {
        localPath = url.standardizedFileURL
        UserDefaults.standard.set(localPath.path, forKey: Self.localKey)
        refreshLocal()
    }

    // MARK: Transfers

    /// Remote → this Mac, into the local folder. A name that exists asks
    /// first; a name the server made up (`../x`) is skipped.
    func download(_ entries: [RemoteEntry]) {
        for entry in entries where !entry.isDirectory {
            guard let name = FilesPlan.localName(forRemote: entry.name) else { continue }
            let target = localPath.appendingPathComponent(name)
            let exists = FileManager.default.fileExists(atPath: target.path)
            guard confirmReplace(name, exists: exists) else { continue }
            // The folder as it is NOW — a queued download must not read a
            // folder the user browsed to after queueing it.
            let source = FilesPlan.join(remotePath, entry.name)
            enqueue(name: name, upload: false, total: entry.size, saving: target) { client, progress in
                try await client.download(source, to: target, replacing: exists, progress: progress)
            }
        }
    }

    /// Blind mode (TFTP, SCP without SFTP): a path typed by the user.
    func download(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        guard let name = FilesPlan.localName(forRemote: last) else { NSSound.beep(); return }
        let target = localPath.appendingPathComponent(name)
        let exists = FileManager.default.fileExists(atPath: target.path)
        guard confirmReplace(name, exists: exists) else { return }
        enqueue(name: name, upload: false, total: nil, saving: target) { client, progress in
            try await client.download(trimmed, to: target, replacing: exists, progress: progress)
        }
    }

    /// This Mac → remote: into the remote folder (browse) or to `blindPath`.
    func upload(_ urls: [URL], blindPath: String? = nil) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let remote: String
            if let blindPath, !blindPath.trimmingCharacters(in: .whitespaces).isEmpty, urls.count == 1 {
                remote = blindPath.trimmingCharacters(in: .whitespaces)
            } else if canBrowse {
                remote = FilesPlan.join(remotePath, url.lastPathComponent)
            } else {
                remote = url.lastPathComponent
            }
            let exists = canBrowse && remoteEntries.contains { $0.name == url.lastPathComponent } && blindPath == nil
            guard confirmReplace(url.lastPathComponent, exists: exists) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            enqueue(name: url.lastPathComponent, upload: true, total: size) { client, progress in
                try await client.upload(url, to: remote, progress: progress)
            }
        }
    }

    private func confirmReplace(_ name: String, exists: Bool) -> Bool {
        guard exists else { return true }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Replace “\(name)”?")
        alert.informativeText = String(localized: "A file with that name is already there.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Replace"))
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn
    }

    /// A finished transfer into the Transfer Log.
    private func log(_ id: UUID, ok: Bool, reason: String = "") {
        guard let t = transfers.first(where: { $0.id == id }) else { return }
        TransferLog.shared.add(TransferLogEntry(date: Date(), proto: protocolLabel, device: endpoint.host, name: t.name,
                                                toMac: !t.isUpload, bytes: t.done, ok: ok, reason: reason))
    }

    /// One transfer at a time per tab, in order (the engines serialise
    /// anyway; a queue keeps the bars honest).
    /// `saving`: a download's destination — a volume that would not keep the
    /// quarantine mark says so in the Transfer Log.
    private func enqueue(name: String, upload: Bool, total: Int64?, saving: URL? = nil,
                         _ body: @escaping @MainActor (RemoteFileClient, @escaping TransferProgress) async throws -> Void) {
        guard let client else { return }
        var item = Transfer(name: name, isUpload: upload)
        item.total = total
        transfers.insert(item, at: 0)
        let id = item.id
        let previous = queueTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { self?.update(id) { $0.state = .cancelled }; return }
            self.update(id) { $0.state = .active }
            let throttle = FilesProgressGate()
            do {
                try await body(client) { [weak self] done, total in
                    guard throttle.shouldReport() else { return }
                    Task { @MainActor in
                        self?.update(id) { $0.done = done; if let total { $0.total = total } }
                    }
                }
                self.update(id) { $0.state = .done; if let t = $0.total { $0.done = t } }
                let unmarked = saving.map { !Quarantine.isMarked($0) } ?? false
                self.log(id, ok: true, reason: unmarked ? Quarantine.unmarkedNote : "")
                if upload { await self.list(self.remotePath) } else { self.refreshLocal() }
            } catch {
                let why = (error as? RemoteFileError) ?? .remote(String(describing: error))
                self.update(id) { $0.state = why == .cancelled ? .cancelled : .failed(why.description) }
                self.log(id, ok: false, reason: why.description)
            }
            self.transferTasks[id] = nil
            self.trimTransfers()
        }
        transferTasks[id] = task
        queueTail = task
    }

    /// Transfers queued or moving (Quit asks while there are any).
    var busyTransfers: Int { transfers.filter { $0.state == .active || $0.state == .queued }.count }

    func cancel(_ transfer: Transfer) {
        transferTasks[transfer.id]?.cancel()
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .active && $0.state != .queued }
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func trimTransfers() {
        let finished = transfers.indices.filter { transfers[$0].state == .done }
        if finished.count > 6 { transfers.remove(at: finished.last!) }
    }

    // MARK: Lifetime

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        closed = true
        transferTasks.values.forEach { $0.cancel() }
        client?.close()
        client = nil
    }
}

/// At most ~8 progress hops to main per second from an engine's queue.
nonisolated final class FilesProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldReport() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.12 else { return false }
            last = now
            return true
        }
    }
}

extension FilesTabController: PaneContent {
    var paneView: NSView { hosting }
    var keyView: NSView { hosting }
    var hasPrompt: Bool { phase != .connected }
    var promptHasKeyboard: Bool { phase != .connected && card.hasKeyboard }
    func focusPrompt() -> Bool { phase != .connected && card.takeKeyboard() }
    func paneDidHide() {}
    func setPointerNeedsFocus(_ needsFocus: Bool) {}
    func refreshFocusAppearance() {}
}
