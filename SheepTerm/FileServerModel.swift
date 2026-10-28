import AppKit
import Combine
import Foundation

/// A server engine the File Server runs (TFTP, SSH for SFTP+SCP, FTP).
nonisolated protocol FileServerEngine: AnyObject, Sendable {
    func start(preferredPort: UInt16) async throws -> UInt16
    func stop()
    /// End every upload in flight (writes switched off / folder changed).
    func abortWrites()
}

extension TFTPServer: FileServerEngine {}

/// File ▸ File Server: the servers a device pulls a file from (`copy
/// tftp://<mac>/…`, `copy scp://sheepterm@<mac>/…`) or pushes a config
/// backup to. Every server is off at launch; writes are off at launch and
/// whenever every server stops; the login password is new every launch and
/// never stored; a server with no accepted transfer for
/// `FileServerPlan.idleLimit` turns itself off. The rules live in
/// `FileServerPlan`; this is the state the popover shows.
@MainActor
final class FileServerModel: ObservableObject {
    static let shared = FileServerModel()

    /// One switch per server; SFTP and SCP share the SSH one.
    enum Server: String, CaseIterable, Identifiable, Sendable {
        case tftp, ssh, ftp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tftp: return "TFTP"
            case .ssh: return "SFTP · SCP"
            case .ftp: return "FTP"
            }
        }
        /// The popover chip: short. SCP stands for the SSH server (it serves
        /// SFTP on the same login).
        var chipLabel: String {
            switch self {
            case .tftp: return "TFTP"
            case .ssh: return "SCP"
            case .ftp: return "FTP"
            }
        }
        var protocols: [FileServerPlan.Proto] {
            switch self {
            case .tftp: return [.tftp]
            case .ssh: return [.scp, .sftp]
            case .ftp: return [.ftp]
            }
        }
        var preferredPort: UInt16 {
            switch self {
            case .tftp: return 69
            case .ssh: return 22
            case .ftp: return 21
            }
        }
        /// Asks for the login (the popover shows it only then).
        var needsLogin: Bool { self != .tftp }
    }

    @Published private(set) var running: [Server: UInt16] = [:] { didSet { publishActive() } }
    @Published private(set) var starting: Set<Server> = [] { didSet { publishActive() } }
    @Published private(set) var startError: String?
    /// The protocol chip picked last: the popover's command uses it.
    @Published private(set) var chosenProto: FileServerPlan.Proto?
    /// The one file a device may read. Kept across launches (the path only).
    @Published private(set) var servedFile: URL? {
        didSet {
            UserDefaults.standard.set(servedFile?.path, forKey: Self.fileKey)
            options.update { $0.served = servedFile }
        }
    }
    /// Off at every launch, and again whenever every server has stopped — a
    /// backup target is opened on purpose each time.
    @Published var allowWrites = false {
        didSet {
            options.update { $0.writes = allowWrites }
            if !allowWrites { engines.values.forEach { $0.abortWrites() } }
            // A new budget each time it is switched on (half the free space).
            if FileServerPlan.startsNewBudget(wasOn: oldValue, isOn: allowWrites, restartingForLogin: restartingForLogin) {
                resetUploadBudget()
            }
        }
    }
    @Published private(set) var writeFolder: URL {
        didSet {
            UserDefaults.standard.set(writeFolder.path, forKey: Self.folderKey)
            options.update { $0.folder = writeFolder }
            engines.values.forEach { $0.abortWrites() }
            // Another folder may be another volume: measure that one.
            if allowWrites { resetUploadBudget() }
        }
    }
    /// Newest first; finished rows stay as a short history.
    @Published private(set) var transfers: [ServerTransfer] = []
    /// The family picked in the popover for a tab that is not a device (or
    /// names none): its copy commands. This launch only.
    @Published var pickedVendor: Vendor?
    /// The popover, opened from the status bar, ＋ or File ▸ File Server….
    @Published var popoverShown = false { didSet { publishActive() } }

    /// The SFTP/SCP/FTP login. The username is a preference; the password
    /// is the user's own (in the Keychain vault, `vaultKey`) or, until one
    /// is set, a fresh random one every launch that is never stored.
    @Published private(set) var username: String =
        UserDefaults.standard.string(forKey: "fileServerUser").flatMap { FileServerPlan.isCommandSafe($0) ? $0 : nil }
        ?? FileServerPlan.serverUsername
    @Published private(set) var password: String = {
        var generator = SystemRandomNumberGenerator()
        return FileServerPlan.newPassword(using: &generator)
    }()
    @Published private(set) var hasOwnPassword = false
    private var savedLoginLoaded = false
    static let vaultKey = "fileserver.password"

    /// Reads the user's own password from the vault once — lazily (when a
    /// login server starts or the login line shows), never at launch.
    func loadSavedLogin() {
        guard !savedLoginLoaded else { return }
        savedLoginLoaded = true
        if let data = PasswordVault.shared.value(for: Self.vaultKey, interactive: true),
           let saved = String(data: data, encoding: .utf8), FileServerPlan.loginProblem(user: username, password: saved) == nil {
            password = saved
            hasOwnPassword = true
        }
    }

    /// Sets the login (an empty password keeps the current one). Returns
    /// the problem to show, or nil when saved. Running login servers are
    /// restarted so the new login applies at once.
    func setLogin(user: String, password newPassword: String) -> String? {
        let user = user.trimmingCharacters(in: .whitespaces)
        let pass = newPassword.isEmpty ? password : newPassword
        if let problem = FileServerPlan.loginProblem(user: user, password: pass) { return problem }
        if !newPassword.isEmpty {
            guard PasswordVault.shared.set(Data(newPassword.utf8), for: Self.vaultKey, interactive: true) else {
                return String(localized: "Could not save the password in the Keychain.")
            }
            password = newPassword
            hasOwnPassword = true
        }
        username = user
        UserDefaults.standard.set(user, forKey: "fileServerUser")
        restartLoginServers()
        return nil
    }

    /// Back to a random password every launch (the saved one is removed).
    func forgetOwnPassword() {
        PasswordVault.shared.remove(Self.vaultKey, interactive: true)
        var generator = SystemRandomNumberGenerator()
        password = FileServerPlan.newPassword(using: &generator)
        hasOwnPassword = false
        restartLoginServers()
    }

    private var restartingForLogin = false

    private func restartLoginServers() {
        let writes = allowWrites      // a stop of the last server would reset it
        restartingForLogin = true
        defer { restartingForLogin = false }
        for kind in Server.allCases where kind.needsLogin && running[kind] != nil {
            stop(kind)
            start(kind)
        }
        if writes, !engines.isEmpty { allowWrites = true }
    }

    private static let fileKey = "fileServerFile"
    private static let folderKey = "fileServerWriteFolder"
    private static let historyLimit = 3

    /// What the servers' queues read per request — the main-actor
    /// properties above, mirrored under a lock.
    private let options = LockedOptions()
    private var engines: [Server: FileServerEngine] = [:]
    private var lastActivity: [Server: Date] = [:]
    private var idleTimer: Timer?

    /// Host keys for the SFTP/SCP server, made once.
    static var hostKeyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm/ServerHostKeys", isDirectory: true)
    }

    /// Where pushed backups land unless the user picks another folder: a
    /// subfolder, so a device never drops files among the user's downloads.
    static var defaultWriteFolder: URL {
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            .appendingPathComponent("SheepTerm Backups", isDirectory: true)
    }

    private init() {
        let folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultWriteFolder
        writeFolder = folder
        let file = UserDefaults.standard.string(forKey: Self.fileKey).map { URL(fileURLWithPath: $0) }
        servedFile = file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        options.update {
            $0.served = servedFile
            $0.folder = folder
        }
    }

    var isAnyRunning: Bool { !running.isEmpty }

    /// Tells the bottom bar whether the glyph must show even when its
    /// View → Bottom Bar Items switch is off. Only on a change.
    private func publishActive() {
        let active = FileServerPlan.showsGlyph(switchOn: false, running: !running.isEmpty,
                                               starting: !starting.isEmpty, popoverOpen: popoverShown)
        if AppModel.shared.fileServerActive != active { AppModel.shared.fileServerActive = active }
    }
    func isOn(_ server: Server) -> Bool { running[server] != nil || starting.contains(server) }
    var inFlight: Int { transfers.filter { $0.state == .active }.count }

    // MARK: On / off

    func setRunning(_ server: Server, _ on: Bool) {
        on ? start(server) : stop(server)
    }

    private func makeEngine(_ server: Server) -> FileServerEngine? {
        let options = self.options
        let readURL: @Sendable (String) -> URL? = { name in
            FileServerPlan.readTarget(requested: name, served: options.value.served)
        }
        let writeURL: @Sendable (String) -> URL? = { name in
            let o = options.value
            guard o.writes, let folder = o.folder else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return FileServerPlan.writeTarget(requested: name, folder: folder,
                                              exists: { FileManager.default.fileExists(atPath: $0.path) })
        }
        let onProgress: @Sendable (ServerTransfer) -> Void = { transfer in
            Task { @MainActor in FileServerModel.shared.received(transfer, from: server) }
        }
        let access = FileServerAccess(readURL: readURL, writeURL: writeURL,
                                      listing: { options.value.served.map { [$0] } ?? [] },
                                      username: username, password: password, onProgress: onProgress)
        switch server {
        case .tftp:
            let tftp = TFTPServer(readURL: access.readURL, writeURL: access.writeURL, onProgress: access.onProgress)
            tftp.onListenerFailed = { why in
                Task { @MainActor in FileServerModel.shared.engineFailed(server, why) }
            }
            return tftp
        case .ssh:
            return FileServerEngines.ssh?(access, Self.hostKeyDirectory)
        case .ftp:
            return FileServerEngines.ftp?(access)
        }
    }

    func start(_ server: Server) {
        guard running[server] == nil, !starting.contains(server) else { return }
        if server.needsLogin { loadSavedLogin() }
        guard let engine = makeEngine(server) else {
            startError = String(localized: "\(server.label) is not available in this build.")
            return
        }
        starting.insert(server)
        startError = nil
        engines[server] = engine
        Task {
            do {
                let bound = try await engine.start(preferredPort: server.preferredPort)
                // Stopped (or restarted) while binding: this engine is stale.
                guard engines[server] === engine else { engine.stop(); return }
                running[server] = bound
                lastActivity[server] = Date()
                armIdleTimer()
            } catch {
                guard engines[server] === engine else { return }
                engines[server] = nil
                if let busy = error as? TFTPServer.PortInUse {
                    startError = busy.description
                } else {
                    startError = String(localized: "Could not start \(server.label): \(String(describing: error))")
                }
            }
            starting.remove(server)
        }
    }

    func stop(_ server: Server) {
        engines[server]?.stop()
        engines[server] = nil
        running[server] = nil
        starting.remove(server)
        lastActivity[server] = nil
        if engines.isEmpty {
            idleTimer?.invalidate()
            idleTimer = nil
            allowWrites = false
        }
        var cut: ServerTransfer?
        for index in transfers.indices where transfers[index].state == .active && transfers[index].server == server.rawValue {
            transfers[index].state = .failed
            transfers[index].detail = String(localized: "stopped")
            cut = transfers[index]
            Self.log(transfers[index])
        }
        publishStrip(finished: cut)
    }

    static func server(for proto: FileServerPlan.Proto) -> Server {
        switch proto {
        case .tftp: return .tftp
        case .sftp, .scp: return .ssh
        case .ftp: return .ftp
        }
    }

    func isOn(_ proto: FileServerPlan.Proto) -> Bool { isOn(Self.server(for: proto)) }

    /// A protocol chip: off → start its server and show its command; on but
    /// not the one shown → show its command (SFTP and SCP share one server);
    /// on and shown → stop its server.
    func tapChip(_ proto: FileServerPlan.Proto) {
        let kind = Self.server(for: proto)
        switch FileServerPlan.chipAction(serverOn: isOn(kind), shownProto: commandProto, tapped: proto) {
        case .start: chosenProto = proto; start(kind)
        case .show: chosenProto = proto
        case .stop: stop(kind)
        }
    }

    /// The protocol the command is shown for: the chip picked last while its
    /// server is on, else the first one that is on.
    var commandProto: FileServerPlan.Proto? {
        if let chosenProto, running[Self.server(for: chosenProto)] != nil { return chosenProto }
        return FileServerPlan.Proto.allCases.first { running[Self.server(for: $0)] != nil }
    }

    func stopAll() {
        Server.allCases.forEach(stop)
    }

    private func engineFailed(_ server: Server, _ why: String) {
        guard running[server] != nil else { return }
        stop(server)
        startError = String(localized: "\(server.label) stopped: \(why)")
    }

    private func armIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in FileServerModel.shared.checkIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func checkIdle(now: Date = Date()) {
        for server in Array(running.keys) {
            let busy = transfers.filter { $0.state == .active && $0.server == server.rawValue }.count
            if FileServerPlan.shouldStop(lastActivity: lastActivity[server] ?? now, now: now, transfersInFlight: busy) {
                stop(server)
            }
        }
    }

    // MARK: Transfers

    /// Progress arrives every ~128 KB (dozens a second on a fast link); the
    /// UI hears at most one batch per `flushInterval` — a start, an end or a
    /// failure is shown at once, a moving bar only on the next flush.
    private static let flushInterval: TimeInterval = 0.2
    private var pending: [String: ServerTransfer] = [:]
    private var flushScheduled = false

    private func received(_ incoming: ServerTransfer, from server: Server) {
        // After Stop, only a finish for a bar we already show gets through:
        // a file that landed as Stop was pressed is a Success, not "stopped".
        guard running[server] != nil
              || (incoming.state == .done && transfers.contains { $0.id == incoming.id }) else { return }
        var transfer = incoming
        transfer.server = server.rawValue
        // Only an ACCEPTED transfer keeps the server awake: a scanner or a
        // device retrying a mistyped name must not defeat the auto-off.
        let known = transfers.contains { $0.id == transfer.id }
        let counts = FileServerPlan.counts(failed: transfer.state == .failed, done: transfer.done, shownBefore: known)
        if counts.keepsAwake { lastActivity[server] = Date() }
        let accepted = counts.accepted
        if known && transfer.state == .active {
            pending[transfer.id] = transfer
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) {
                MainActor.assumeIsolated { FileServerModel.shared.flushPending() }
            }
            return
        }
        pending[transfer.id] = nil
        apply(transfer, accepted: accepted)
    }

    private func flushPending() {
        flushScheduled = false
        let batch = pending
        pending.removeAll()
        for transfer in batch.values where running[Server(rawValue: transfer.server) ?? .tftp] != nil {
            apply(transfer)
        }
    }

    private func checkUploadBudget(after transfer: ServerTransfer, finishesNow: Bool) {
        guard transfer.isUpload else { return }
        // Counted once: a repeated .done for the same row adds nothing.
        if transfer.state == .done && finishesNow {
            receivedSinceOn += transfer.done
            filesSinceOn += 1
        }
        let inFlight = transfers.filter { $0.isUpload && $0.state == .active }.reduce(Int64(0)) { $0 + $1.done }
        guard allowWrites else { return }
        if FileServerPlan.overUploadBudget(received: receivedSinceOn, inFlight: inFlight, budget: writeBudget) {
            allowWrites = false      // aborts what is still coming in
            startError = String(localized: "Receive files turned off: devices sent half the free disk space.")
        } else if filesSinceOn >= FileServerPlan.maximumUploadFiles {
            allowWrites = false
            startError = String(localized: "Receive files turned off: devices sent 1,000 files.")
        }
    }

    /// The last transfer to finish while nothing else moves: the bottom bar
    /// shows its ✓ / ✕ for `outcomeSeconds`, then gives the bar back.
    @Published private(set) var stripOutcome: ServerTransfer?
    static let outcomeSeconds = 4.0
    private var outcomeClear: DispatchWorkItem?

    /// A transfer that just ended, into the Transfer Log. (`isUpload` on
    /// the server side = the device wrote to this Mac.)
    /// Refusals per peer in the last minute: a scanner asking for names
    /// (no login on TFTP) must not push the real history out of the log.
    private static var refusals: [String: [Date]] = [:]

    private static func log(_ t: ServerTransfer) {
        if t.state == .failed && t.done == 0 {
            let now = Date()
            let recent = (refusals[t.peer] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard recent.count < 5 else { refusals[t.peer] = recent; return }
            refusals[t.peer] = recent + [now]
            if refusals.count > 256 { refusals = refusals.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last!) < 60 } }
        }
        let proto = ["tftp": "TFTP", "ftp": "FTP"][t.server] ?? "SFTP/SCP"
        TransferLog.shared.add(TransferLogEntry(date: Date(), proto: proto, device: t.peer, name: t.name,
                                                toMac: t.isUpload, bytes: t.done, ok: t.state == .done, reason: t.detail))
    }

    private func publishStrip(finished: ServerTransfer? = nil) {
        if inFlight > 0 {
            stripOutcome = nil
            outcomeClear?.cancel()
        } else if let finished {
            stripOutcome = finished
            outcomeClear?.cancel()
            let clear = DispatchWorkItem { [weak self] in self?.stripOutcome = nil; self?.publishStrip() }
            outcomeClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.outcomeSeconds, execute: clear)
        }
        let shown = inFlight > 0 || stripOutcome != nil
        if AppModel.shared.fileTransferShown != shown { AppModel.shared.fileTransferShown = shown }
    }

    /// `accepted` false = a refused request (wrong name, writes off, a
    /// scanner): its row shows in the popover, but it neither takes the
    /// bottom bar nor goes into the Transfer Log (review 6.0).
    /// Bytes devices sent and kept since Receive files was switched on, and
    /// what they may send in all (`FileServerPlan.uploadBudget`).
    private var receivedSinceOn: Int64 = 0
    private var filesSinceOn = 0
    private var writeBudget: Int64 = 0

    /// Half the free space of the write folder's volume, measured now. The
    /// folder may not exist yet (made at the first upload): its nearest
    /// existing parent is measured; nothing measurable = no budget.
    private func resetUploadBudget() {
        receivedSinceOn = 0
        filesSinceOn = 0
        writeBudget = FileServerPlan.uploadBudget(freeWhenTurnedOn: FileServerPlan.freeSpace(near: writeFolder) ?? 0)
    }

    private func apply(_ transfer: ServerTransfer, accepted: Bool = true) {
        let finishesNow = FileServerPlan.finishesNow(previous: transfers.first(where: { $0.id == transfer.id })?.state,
                                                     incoming: transfer.state)
        defer {
            if accepted { publishStrip(finished: transfer.state == .active ? nil : transfer) }
            checkUploadBudget(after: transfer, finishesNow: finishesNow)
        }
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            // A late progress tick must not undo a finished/failed state.
            guard transfers[index].state == .active || transfer.state != .active else { return }
            if accepted && transfers[index].state == .active && transfer.state != .active { Self.log(transfer) }
            transfers[index] = transfer
        } else {
            if accepted && transfer.state != .active { Self.log(transfer) }
            transfers.insert(transfer, at: 0)
            // Keep every live bar; trim only finished history.
            while transfers.count > Self.historyLimit,
                  let last = transfers.lastIndex(where: { $0.state != .active }) {
                transfers.remove(at: last)
            }
        }
    }

    // MARK: Files

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let servedFile { panel.directoryURL = servedFile.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setServedFile(url)
    }

    func setServedFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        servedFile = url.standardizedFileURL
    }

    /// The picked file was moved or deleted since: forget it rather than
    /// promise a command that will fail.
    func revalidateServedFile() {
        if let servedFile, !FileManager.default.fileExists(atPath: servedFile.path) { self.servedFile = nil }
    }

    func chooseWriteFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        try? FileManager.default.createDirectory(at: writeFolder, withIntermediateDirectories: true)
        panel.directoryURL = writeFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeFolder = url.standardizedFileURL
    }

    func revealWriteFolder() {
        try? FileManager.default.createDirectory(at: writeFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(writeFolder)
    }
}

/// Factories for the SSH (SFTP+SCP) and FTP server engines, set where those
/// engines are compiled in (`FileServerEngines+SSHFTP.swift`).
@MainActor
enum FileServerEngines {
    static var ssh: ((FileServerAccess, URL) -> FileServerEngine)?
    static var ftp: ((FileServerAccess) -> FileServerEngine)?
}

/// The options box the server queues read.
nonisolated private final class LockedOptions: @unchecked Sendable {
    struct Value: Sendable {
        var served: URL?
        var writes = false
        var folder: URL?
    }
    private let lock = NSLock()
    private var stored = Value()
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
