import AppKit

/// ZMODEM in a terminal tab (6.1 (37)): watches what the device prints for
/// the header `sz` or `rz` opens with, asks, and then runs the transfer on
/// the tab's own line (`ZModemReceiver` / `ZModemSender`).
///
/// Nothing is sent before the user says so: `sz` gets no answer until
/// Receive is clicked, `rz` none until a file is picked — a cancel sends the
/// protocol's abort. Received files go to Downloads under the name the
/// sender gave (its last path component, made safe; never over a file that
/// is there), quarantined like any download. While a transfer runs the
/// device's bytes are the transfer's, not the terminal's, and are not logged.
@MainActor final class ZModemDriver {
    /// The tab's line, as the driver needs it.
    struct Line {
        /// Raw bytes to the device; false = refused.
        var write: ([UInt8]) -> Bool
        /// Whether the line can take a few more kilobytes now.
        var hasRoom: () -> Bool
        var window: () -> NSWindow?
        var notice: (String, Bool) -> Void
        /// On while a transfer runs: the session log skips its bytes.
        var muteLog: (Bool) -> Void
        /// Off where the line is not 8-bit clean or is busy (telnet, an XMODEM transfer).
        var isAvailable: () -> Bool
        /// On while `isBusy` (a question or a transfer): the line is this
        /// transfer's — Break, a speed change, XMODEM, pastes, snippets and
        /// Broadcast are refused (`ConsoleWorker.claimLine`, `lineBusy`).
        var claim: (Bool) -> Void = { _ in }
    }

    private enum State {
        case idle
        case asking
        case receiving(ZModemReceiver)
        case sending(ZModemSender, name: String)
        /// We cancelled: what the far end still had on its way is swallowed.
        case draining(ZModem.Drain)
    }

    private let line: Line
    private weak var host: SessionTerminalHost?
    private var state: State = .idle {
        didSet {
            guard isBusy != claimed else { return }
            claimed = isBusy
            line.claim(claimed)
        }
    }
    /// What `line.claim` was last told.
    private var claimed = false
    private var watcher = ZModem.Watcher()
    /// What arrived since the offer while the question is up (the offer itself, repeated).
    private var held: [UInt8] = []
    /// The two "O"s a sender signs off with, still to come.
    private var signOff = ZModem.SignOff()
    private var signOffUntil = 0.0
    private var timer: Timer?
    private var lastHUD = 0.0
    private var incoming: (handle: FileHandle, part: URL, name: String, size: Int, got: Int)?
    private var landed: [String] = []
    /// Largest file sent: it is read whole, and a position is 32 bits.
    static let maxSendBytes = 1 << 30

    init(line: Line, host: SessionTerminalHost) {
        self.line = line
        self.host = host
    }

    /// A question is up or a transfer is running: the keyboard is not the device's.
    var isBusy: Bool {
        if case .idle = state { return false }
        return true
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// The device's bytes on their way to the terminal: what comes back is
    /// what the terminal still shows.
    func filter(_ bytes: [UInt8]) -> [UInt8] {
        switch state {
        case .idle:
            // The sign-off follows the transfer at once or not at all: what
            // the device prints later is never taken for it.
            if signOff.isWaiting, Self.now() > signOffUntil { signOff.clear() }
            let bytes = signOff.strip(bytes)
            guard UserDefaults.standard.object(forKey: "zmodemOffers") as? Bool ?? true, line.isAvailable(),
                  let found = watcher.scan(bytes) else { return bytes }
            held = found.carried + Array(bytes[found.start...])
            state = .asking
            ask(found.offer)
            return Array(bytes[..<found.start])
        case .asking:
            held += bytes
            if held.count > 8192 { held.removeFirst(held.count - 8192) }
            return []
        case .receiving(var receiver):
            let (out, rest) = receiver.receiveSplit(bytes, now: Self.now())
            state = .receiving(receiver)
            apply(out)
            // What followed the end in the same read is the terminal's again.
            return rest.isEmpty ? [] : filter(rest)
        case .sending(var sender, let name):
            let (out, rest) = sender.receiveSplit(bytes, now: Self.now())
            state = .sending(sender, name: name)
            apply(out)
            return rest.isEmpty ? [] : filter(rest)
        case .draining(var drain):
            guard drain.swallow(bytes.count, now: Self.now()) else {
                endDrain()
                return filter(bytes)
            }
            state = .draining(drain)
            return []
        }
    }

    private var isTransferring: Bool {
        switch state {
        case .receiving, .sending: return true
        case .idle, .asking, .draining: return false
        }
    }

    private func endDrain() {
        timer?.invalidate()
        timer = nil
        state = .idle
        line.muteLog(false)
    }

    /// The tab is closing or its session ended.
    func sessionEnded() {
        guard isBusy else { return }
        discardIncoming()
        finish(notice: nil, error: false)
    }

    // MARK: Asking

    private func ask(_ offer: ZModem.Offer) {
        guard let window = line.window() else { refuse(); return }
        switch offer {
        case .sending:
            let alert = SheepAlert()
            alert.messageText = String(localized: "Receive a file?")
            alert.informativeText = String(localized: "The device started a ZMODEM send (sz). Files go to Downloads.")
            alert.addButton(withTitle: String(localized: "Receive"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.sheepStyled().beginSheetModal(for: window) { [weak self] response in
                guard let self, case .asking = self.state else { return }
                guard response == .alertFirstButtonReturn else { self.refuse(); return }
                var receiver = ZModemReceiver(now: Self.now())
                let out = receiver.start(now: Self.now())
                self.held = []
                self.landed = []
                self.state = .receiving(receiver)
                self.begin()
                self.apply(out)
            }
        case .receiving:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = String(localized: "The device is waiting for a file (rz).")
            panel.prompt = String(localized: "Send")
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, case .asking = self.state else { return }
                guard response == .OK, let url = panel.url else { self.refuse(); return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxSendBytes, let data = try? Data(contentsOf: url) else {
                    self.refuse()
                    self.line.notice(size > Self.maxSendBytes ? "ZMODEM: that file is larger than 1 GB — not sent" : "ZMODEM: the file could not be read — not sent", true)
                    return
                }
                let name = ZModem.safeFileName(url.lastPathComponent)
                var sender = ZModemSender(name: name, data: [UInt8](data), now: Self.now())
                let out = sender.receive(self.held, now: Self.now())
                self.held = []
                self.state = .sending(sender, name: name)
                self.begin()
                self.apply(out)
            }
        }
    }

    /// The user said no (or there is no window to ask in): the far end's
    /// `sz` / `rz` is told to stop.
    private func refuse() {
        _ = line.write(ZModem.cancelSequence)
        held = []
        state = .idle
    }

    // MARK: Running

    private func begin() {
        signOff.clear()
        line.muteLog(true)
        lastHUD = 0
        timer?.invalidate()
        // In the common modes: a menu held open, a window being resized or
        // a modal alert must not stop the transfer (the default mode alone
        // did — and a minute of that read as a dead line, 6.1 (52)).
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        showProgress(force: true)
    }

    private func tick() {
        switch state {
        case .receiving(var receiver):
            let out = receiver.tick(now: Self.now())
            state = .receiving(receiver)
            apply(out)
        case .sending(var sender, let name):
            let out = sender.tick(now: Self.now())
            // A slice of the file while the line has room — never ahead of it.
            var budget = 32
            var refused = false
            while budget > 0, sender.hasData, line.hasRoom() {
                if !line.write(sender.nextData(now: Self.now())) { refused = true; break }
                budget -= 1
            }
            state = .sending(sender, name: name)
            apply(out)
            if refused { stop(reason: "ZMODEM: the line stopped taking data — transfer ended") }
        case .draining(let drain):
            if drain.isOver(now: Self.now()) { endDrain() }
        case .idle, .asking:
            break
        }
        showProgress(force: false)
    }

    /// The HUD's Stop, or a line that died under the transfer.
    private func stop(reason: String?) {
        var out = ZModemOutput()
        switch state {
        case .receiving(var receiver): out = receiver.cancel(); state = .receiving(receiver)
        case .sending(var sender, let name): out = sender.cancel(); state = .sending(sender, name: name)
        case .idle, .asking, .draining: return
        }
        _ = line.write(out.send)
        discardIncoming()
        finish(notice: reason ?? "ZMODEM: transfer stopped", error: true, drain: true)
    }

    private func apply(_ out: ZModemOutput) {
        if !out.send.isEmpty { _ = line.write(out.send) }
        for event in out.events {
            // A stop on the way (no room in Downloads) ends the rest too.
            guard isTransferring else { return }
            switch event {
            case .fileBegan(let name, let size):
                // Still open = its ZEOF never came: the sender is starting
                // this file over (a repeated ZFILE), not sending another.
                discardIncoming()
                openIncoming(name: name, size: size)
            case .fileData(let bytes):
                guard incoming != nil else { continue }
                do {
                    try incoming?.handle.write(contentsOf: Data(bytes))
                    incoming?.got += bytes.count
                } catch {
                    stop(reason: "ZMODEM: could not write to Downloads — transfer ended")
                    return
                }
            case .fileEnded:
                closeIncoming(keep: true)
            case .finished:
                if case .sending(let sender, let name) = state {
                    expectSignOff(os: 0)
                    finish(notice: "ZMODEM: sent \(name) (\(sender.total) bytes)", error: false)
                } else {
                    // A file still open never had its ZEOF (the sender gave
                    // up half-way with ZFIN): it is not a file received.
                    let unfinished = incoming?.name
                    discardIncoming()
                    expectSignOff(os: 2)
                    let said = ZModem.receivedNotice(landed: landed, unfinished: unfinished)
                    finish(notice: said.text, error: said.error)
                }
            case .failed(let failure):
                discardIncoming()
                // Ours to end (we sent the cancel: a timeout, a refusal): the
                // far end may still be sending. One that stopped by itself is
                // back at its prompt, and that is the terminal's.
                let ours = out.send.suffix(ZModem.cancelSequence.count) == ZModem.cancelSequence[...]
                // Its last header's CR LF XON still follow (a skip, an abort).
                if !ours { expectSignOff(os: 0) }
                finish(notice: "ZMODEM: \(Self.describe(failure))", error: true, drain: ours)
            }
        }
    }

    private func expectSignOff(os: Int) {
        signOff.expect(os: os)
        signOffUntil = Self.now() + 2
    }

    private func finish(notice: String?, error: Bool, drain: Bool = false) {
        held = []
        host?.hideStatusHUD()
        if drain {
            // The timer keeps running: it is what ends the drain.
            state = .draining(ZModem.Drain(now: Self.now()))
        } else {
            timer?.invalidate()
            timer = nil
            state = .idle
            line.muteLog(false)
        }
        if let notice { line.notice(notice, error) }
    }

    static func describe(_ failure: ZModemFailure) -> String {
        switch failure {
        case .cancelledByPeer: return "the device cancelled the transfer"
        case .cancelledByUser: return "transfer stopped"
        case .timedOut: return "no answer from the device — transfer ended"
        case .refused(let why): return why
        case .sessionEnded: return "the session ended"
        }
    }

    private func showProgress(force: Bool) {
        let now = Self.now()
        guard force || now - lastHUD > 0.25 else { return }
        lastHUD = now
        let text: String
        switch state {
        case .receiving:
            guard let incoming else { text = "ZMODEM ↓"; break }
            text = "ZMODEM ↓ \(incoming.name) · " + Self.progress(incoming.got, of: incoming.size)
        case .sending(let sender, let name):
            text = "ZMODEM ↑ \(name) · " + Self.progress(sender.position, of: sender.total)
        case .idle, .asking, .draining:
            return
        }
        host?.showStatusHUD(text, stopHelp: String(localized: "Stop the transfer")) { [weak self] in self?.stop(reason: nil) }
    }

    static func progress(_ done: Int, of total: Int) -> String {
        guard total > 0 else { return ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file) }
        return "\(min(100, Int((Double(done) / Double(total) * 100).rounded(.down))))%"
    }

    // MARK: The file being received

    private func openIncoming(name: String, size: Int) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let safe = ZModem.safeFileName(name)
        // Written beside its place under a hidden name, moved in when whole.
        let part = folder.appendingPathComponent(".\(safe).\(UUID().uuidString.prefix(8)).sheepterm-part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else {
            stop(reason: "ZMODEM: could not create a file in Downloads — transfer ended")
            return
        }
        incoming = (handle, part, safe, size, 0)
    }

    private func closeIncoming(keep: Bool) {
        guard let file = incoming else { return }
        incoming = nil
        try? file.handle.close()
        guard keep else { try? FileManager.default.removeItem(at: file.part); return }
        let folder = file.part.deletingLastPathComponent()
        let name = ZModem.freeFileName(file.name) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let final = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: file.part, to: final)
            Quarantine.mark(final)
            landed.append(name)
        } catch {
            try? FileManager.default.removeItem(at: file.part)
        }
    }

    private func discardIncoming() { closeIncoming(keep: false) }
}
