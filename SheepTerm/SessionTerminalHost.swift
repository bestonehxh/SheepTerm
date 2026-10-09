import AppKit
import SheepVTRender

/// Auto-hiding scrollbar: invisible at rest, appears while scrolling and
/// fades back out (modern macOS overlay behavior — the package's scroller is
/// shown as soon as there is scrollback and never fades on its own).
/// Alpha only, so the terminal never reflows.
@MainActor
final class ScrollerFader {
    private weak var scroller: NSScroller?
    private weak var view: NSView?
    private var lastFlash = Date.distantPast
    private var fadePending = false

    /// One app-level scroll monitor fans out to every attached fader —
    /// N tabs would otherwise stack N local monitors on each scroll event.
    private static let registry = NSHashTable<ScrollerFader>.weakObjects()
    private static var monitor: Any?

    func attach(in view: NSView) {
        guard scroller == nil else { return }
        scroller = view.subviews.compactMap { $0 as? NSScroller }.first
        scroller?.alphaValue = 0
        self.view = view
        Self.registry.add(self)
        Self.installMonitorIfNeeded()
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        // The terminal view handles scrollWheel itself; watch the events and
        // forward to the fader whose view is under the pointer.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                for fader in registry.allObjects {
                    guard let view = fader.view, event.window === view.window,
                          view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                    else { continue }
                    fader.flash()
                    break
                }
            }
            return event
        }
    }

    // No explicit unregister in deinit: the weak registry drops deallocated
    // faders on its own, and the shared monitor lives for the app's lifetime.

    func flash() {
        guard let scroller else { return }
        lastFlash = Date()
        scroller.alphaValue = 1
        // At most one pending fade block — a scroll storm would otherwise
        // queue an asyncAfter closure per event.
        guard !fadePending else { return }
        fadePending = true
        scheduleFade()
    }

    private func scheduleFade() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak scroller] in
            guard let self else { return }
            // Scrolled again during the wait — re-arm instead of fading.
            if Date().timeIntervalSince(self.lastFlash) < 1.0 {
                self.scheduleFade()
                return
            }
            self.fadePending = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                scroller?.animator().alphaValue = 0
            }
        }
    }
}

/// Everything a session tab wraps around its `SheepVTRender.TerminalView`:
/// the view itself, the fading scroller, and SafePaste.
///
/// The view is `final`, so this is composition where 2.x had two subclasses
/// (`SheepSSHTerminalView` / `SheepLocalTerminalView`). One host serves SSH,
/// serial and local; only SafePaste differs, and it is a flag.
@MainActor
final class SessionTerminalHost {
    /// The package default is 10,000 lines, but the app owns the user default
    /// that overrides it. This app exists to read long output —
    /// `display current-configuration` on the Huawei core in the sample logs
    /// is 1,854 lines, a Cisco `show tech-support` runs into five figures, and
    /// scrolling back to the top of one of those is the whole point of having
    /// scrollback at all. Cost is bounded and linear — lines x columns x
    /// ~24 bytes per cell — and only paid for lines actually produced.
    static var scrollbackLines: Int {
        let saved = UserDefaults.standard.integer(forKey: "scrollbackLines")
        return saved > 0 ? min(max(saved, 500), 200_000) : 10_000
    }

    let terminalView: TerminalView

    /// SafePaste is for device CLIs: a multi-line paste into a switch is a
    /// configuration change. The local shell pastes the way every other
    /// macOS terminal does.
    private let safePasteAvailable: Bool

    /// How the owning session answers "did your worker take the bytes of the
    /// `send` I just made?".
    ///
    /// `TerminalViewDelegate.send` returns Void — it is the terminal
    /// package's protocol, not ours — so the controller records what its
    /// `worker.write` answered and hands it back through here. Reading it
    /// CONSUMES it: if the delegate was never called at all (a torn-down
    /// view), the answer is "not accepted", which is the truth.
    ///
    /// Accepted means the worker queued the bytes for the transport. There
    /// is no device acknowledgement anywhere in this design, and nothing may
    /// read this as one.
    var takeLastSendAccepted: (() -> Bool)?

    private let scrollerFader = ScrollerFader()
    private let pastePacer = SafePastePacer()
    private var pastePromptPresented = false
    private var pasteHUD: NSVisualEffectView?
    private var pasteProgressLabel: NSTextField?
    private var sendingPacedLine = false
    /// Set while `sendImmediatePaste` calls back into the view, so the view's
    /// `shouldPaste` veto does not re-enter the SafePaste flow.
    private var pastingImmediately = false
    /// Set around `sendCommand`: the text is the app's, not the clipboard's.
    private var sendingCommand = false

    /// Send text the app composed (Snippets, Broadcast) the way a paste
    /// reaches the device, minus the planted-clipboard question. Returns
    /// whether it went out now (false = Safe Paste took it for its own
    /// question, or the session refused it).
    @discardableResult
    func sendCommand(_ text: String) -> Bool {
        sendingCommand = true
        defer { sendingCommand = false }
        return terminalView.pasteText(text)
    }

    private static let pasteDelayKey = "safePasteDelayMilliseconds"

    // MARK: OSC 52 (remote clipboard write)

    /// Settings → Clipboard. Off unless the user turned it on: a device that
    /// may set the clipboard can plant a command for the user's next ⌘V.
    static let clipboardWriteKey = "allowOSC52ClipboardWrite"
    static var clipboardWriteAllowed: Bool {
        UserDefaults.standard.bool(forKey: clipboardWriteKey)
    }
    /// Process-wide: every tab pastes from the same pasteboard, so text one
    /// tab's device planted must be caught when it is pasted into another.
    private static var plantedClipboard = PlantedClipboard()
    /// The "blocked" line is said once per tab, not once per write — a
    /// device (or tmux's set-clipboard) can try on every copy.
    private var blockedClipboardNoticeShown = false
    /// Set while a paste the user confirmed in the planted-text prompt goes
    /// back through the view, so `shouldPaste` does not ask a second time.
    private var plantedPasteConfirmed = false
    /// Bumped by every prompt AND every cancel, so a stale sheet's answer can
    /// be told from the live one's.
    private var pasteGeneration = 0
    private weak var pastePromptWindow: NSWindow?
    private static let pasteDelayChoices = [50, 100, 200, 300, 500, 1_000]

    /// The session's name for the Safe Paste sheet (set by `AppModel.attach`):
    /// with split panes the sheet is modal for the window, not the pane.
    var sessionLabel: String?

    init(safePaste: Bool) {
        safePasteAvailable = safePaste
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480),
                                    cols: 80, rows: 24,
                                    scrollback: SessionTerminalHost.scrollbackLines)
        scrollerFader.attach(in: terminalView)
    }

    // MARK: - Connection card (4.2 (9))

    /// The card a connecting session shows — stage track, questions,
    /// failure — and where it lives: centred over the dimmed terminal
    /// (`connectionOverlay`, a subview of the TERMINAL view, so a tab switch,
    /// a pane drag or a zoom carry it along and none of them cancels it), or
    /// in a window-centred panel while the pane is too small to hold it.
    /// See `ConnectionCardView` / ARCHITECTURE.md §15.
    private var connectionCard: ConnectionCardView?
    private var connectionOverlay: ConnectionOverlayView?
    private var connectionPanel: ConnectionCardPanel?
    private var cardConstraints: [NSLayoutConstraint] = []
    /// The live question's completion: called exactly once.
    private var questionCompletion: ((ConnectionPromptReply) -> Void)?
    /// What Close / Escape does on the page on screen (progress, failure).
    private var pageClose: (() -> Void)?
    private var pageKnownHosts: (() -> Void)?

    /// The pane is smaller than this: the card goes to a panel instead (the
    /// card never shrinks its font or its width).
    private static let cardMargin: CGFloat = 24
    private static let minPaneHeight: CGFloat = 260

    /// A connection card is on screen (in the pane or in its panel).
    var hasConnectionCard: Bool { connectionCard != nil }
    /// Kept for the call sites that only care about questions.
    var hasPrompt: Bool { connectionCard != nil }

    /// Whether the keyboard is in the card.
    var promptHasKeyboard: Bool { connectionCard?.hasKeyboard ?? false }

    /// Puts the card up (or refreshes its header) on its first page.
    func beginConnectionCard(_ header: ConnectionCardHeader) {
        if connectionCard == nil {
            let card = ConnectionCardView(header: header)
            card.onFocus = { [weak self] in
                guard let self else { return }
                AppModel.shared.noteFocus(view: self.terminalView)
            }
            let overlay = ConnectionOverlayView(frame: terminalView.bounds)
            overlay.card = card
            overlay.onGeometryChange = { [weak self] in self?.placeConnectionCard() }
            connectionCard = card
            connectionOverlay = overlay
            terminalView.addSubview(overlay)
            // The keyboard: taken at once only if this pane already had it.
            // Otherwise the card waits — a click on the pane, the tab being
            // selected or the pane focused moves the keyboard to the
            // terminal, and `terminalTookKeyboard()` hands it on. Nothing is
            // ever taken from the sidebar or another pane.
            let hadKeyboard = terminalView.window?.firstResponder === terminalView
            placeConnectionCard()
            if hadKeyboard { card.takeKeyboard() }
        }
    }

    /// "Connecting…" / "Authenticating…" at `stage`; `onClose` = Close/Esc.
    func showConnectionProgress(_ text: String, stage: ConnectionStage, onClose: @escaping () -> Void) {
        guard let card = connectionCard else { return }
        settleQuestion(.cancel)
        pageClose = onClose
        pageKnownHosts = nil
        card.show(stage: stage, page: .progress(text)) { [weak self] action in self?.cardAction(action) }
        placeConnectionCard()
    }

    /// One of the worker's questions. `completion` is called exactly once:
    /// with the user's answer, or `.cancel` on Escape / Close, when a newer
    /// page replaces it, or when the card is taken down (tab closed).
    func presentPrompt(_ prompt: ConnectionPrompt, header: ConnectionCardHeader,
                       completion: @escaping (ConnectionPromptReply) -> Void) {
        beginConnectionCard(header)
        guard let card = connectionCard else { completion(.cancel); return }
        settleQuestion(.cancel)
        pageClose = nil
        pageKnownHosts = nil
        questionCompletion = completion
        card.show(stage: prompt.stage, page: .question(prompt)) { [weak self] action in self?.cardAction(action) }
        placeConnectionCard()
    }

    /// The connection failed: the reason in red on the card, at the stage it
    /// got to. `onKnownHosts` adds "Open Known Hosts…".
    func showConnectionFailure(title: String, message: String, hostKeyProblem: Bool,
                               onKnownHosts: (() -> Void)?, onClose: @escaping () -> Void) {
        guard let card = connectionCard else { return }
        settleQuestion(.cancel)
        pageClose = onClose
        pageKnownHosts = onKnownHosts
        card.show(stage: card.stage,
                  page: .failure(title: title, message: message, hostKeyProblem: hostKeyProblem,
                                 offersKnownHosts: onKnownHosts != nil)) { [weak self] action in self?.cardAction(action) }
        placeConnectionCard()
    }

    /// Settles a live question with `.cancel` (its worker gets nil); the
    /// card stays. Safe to call with nothing up.
    func dismissPrompt() {
        settleQuestion(.cancel)
    }

    /// Takes the card down — a live question is settled `.cancel` first.
    func closeConnectionCard() {
        settleQuestion(.cancel)
        pageClose = nil
        pageKnownHosts = nil
        guard let card = connectionCard else { return }
        let hadKeyboard = card.hasKeyboard
        connectionCard = nil
        NSLayoutConstraint.deactivate(cardConstraints)
        cardConstraints = []
        card.removeFromSuperview()
        connectionOverlay?.onGeometryChange = nil
        connectionOverlay?.removeFromSuperview()
        connectionOverlay = nil
        if let panel = connectionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            connectionPanel = nil
        }
        // The keyboard goes back to the terminal it came from — the next
        // thing the user types after a login is a command.
        if hadKeyboard, let window = terminalView.window {
            window.makeFirstResponder(terminalView)
        }
    }

    /// The terminal view just became first responder (`focusChanged`): while
    /// a card is up the keyboard belongs to it. Next turn of the run loop —
    /// the terminal is still inside its own becomeFirstResponder — and only
    /// if nothing else has taken the keyboard meanwhile.
    func terminalTookKeyboard() {
        guard connectionCard != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let card = self.connectionCard,
                  self.terminalView.window?.firstResponder === self.terminalView else { return }
            card.takeKeyboard()
        }
    }

    /// Gives the card the keyboard now (the pane was focused on purpose).
    @discardableResult
    func focusPrompt() -> Bool {
        connectionCard?.takeKeyboard() ?? false
    }

    private func settleQuestion(_ reply: ConnectionPromptReply) {
        guard let completion = questionCompletion else { return }
        questionCompletion = nil
        completion(reply)
    }

    private func cardAction(_ action: ConnectionCardAction) {
        switch action {
        case .answer(let reply):
            settleQuestion(reply)
        case .close:
            let close = pageClose
            pageClose = nil
            close?()
        case .openKnownHosts:
            pageKnownHosts?()
        }
    }

    /// In the pane when it fits — centred on the veil — else in a panel
    /// centred over the window. Re-run on every page (the height changes),
    /// every pane resize and every window change (a hidden tab or pane puts
    /// the panel away; coming back brings it back).
    private func placeConnectionCard() {
        guard let card = connectionCard, let overlay = connectionOverlay else { return }
        let hadKeyboard = card.hasKeyboard
        // One size for every stage (the card's fixed frame), so a pane that
        // holds one page holds them all — the card never jumps in and out.
        let needed = ConnectionCardView.cardSize
        let size = overlay.bounds.size
        let fits = size.width >= needed.width + Self.cardMargin
            && size.height >= max(Self.minPaneHeight, needed.height + Self.cardMargin)
        if fits {
            if let panel = connectionPanel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            overlay.veiled = true
            card.drawsChrome = true
            if card.superview !== overlay {
                NSLayoutConstraint.deactivate(cardConstraints)
                card.removeFromSuperview()
                overlay.addSubview(card)
                cardConstraints = [
                    card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                ]
                NSLayoutConstraint.activate(cardConstraints)
                if hadKeyboard { card.takeKeyboard() }
            }
            return
        }
        overlay.veiled = false
        guard let window = overlay.window else {
            // Tab switched away / pane hidden: the panel goes with it.
            if let panel = connectionPanel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            return
        }
        let panel: ConnectionCardPanel
        if let existing = connectionPanel {
            panel = existing
        } else {
            panel = ConnectionCardPanel(title: card.header.windowTitle)
            panel.onClose = { [weak card] in card?.cancelOperation(nil) }
            connectionPanel = panel
        }
        card.drawsChrome = false
        if card.superview !== panel.contentView, let content = panel.contentView {
            NSLayoutConstraint.deactivate(cardConstraints)
            card.removeFromSuperview()
            content.addSubview(card)
            cardConstraints = [
                card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                card.topAnchor.constraint(equalTo: content.topAnchor),
                card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
            NSLayoutConstraint.activate(cardConstraints)
        }
        panel.setContentSize(NSSize(width: needed.width, height: needed.height + ConnectionCardView.panelTitleBand))
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            SheepAlert.center(panel, over: window)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        if hadKeyboard { card.takeKeyboard() }
    }

    // MARK: - SafePaste

    /// `TerminalViewDelegate.clipboardWrite`: records a write that reached
    /// the pasteboard and returns the grey line the controller prints, or nil
    /// when there is nothing (more) to say. `source` is "device" or
    /// "program"; every message is fixed text plus a number — nothing the
    /// device sent is echoed.
    func clipboardWriteNotice(_ outcome: ClipboardWriteOutcome, source: String) -> String? {
        switch outcome {
        case .written(let bytes, let changeCount):
            Self.plantedClipboard.noteDeviceWrite(reachedPasteboard: true, changeCount: changeCount)
            return "the \(source) set the clipboard (\(bytes) bytes) — pasting it will ask first"
        case .blocked:
            guard !blockedClipboardNoticeShown else { return nil }
            blockedClipboardNoticeShown = true
            return "the \(source) tried to set the clipboard — blocked; allow it in Settings → Clipboard"
        case .tooLarge(let bytes):
            return "the \(source) tried to set the clipboard with \(bytes) bytes — refused, that is far more than a copy"
        }
    }

    /// `TerminalViewDelegate.shouldPaste`: true lets the view paste normally,
    /// false means this host has taken the text over.
    ///
    /// Every paste in the app reaches here: ⌘V, Edit → Paste and the
    /// terminal's context-menu Paste all send `paste:` to the view, which asks
    /// this before sending a byte (middle-click paste and text drops do not
    /// exist in the view). Text a device planted is asked about first — in
    /// every tab kind and whatever Safe Paste is set to.
    func shouldPaste(_ text: String) -> Bool {
        // The planted-clipboard question is about the CLIPBOARD: text the
        // app composed itself (a snippet, a broadcast line) never came from
        // it, so it is not asked — Safe Paste below still applies to it.
        if !pastingImmediately, !sendingCommand, !plantedPasteConfirmed,
           Self.plantedClipboard.needsConfirmation(currentChangeCount: terminalView.pasteboard.changeCount) {
            guard !pastePromptPresented else {
                NSSound.beep()
                return false
            }
            presentPlantedPasteConfirmation(text)
            return false
        }
        guard safePasteAvailable, !pastingImmediately, AppModel.shared.safePasteEnabled else {
            return true
        }
        guard !pastePromptPresented else {
            NSSound.beep()
            return false
        }

        let plan: SafePastePlan
        do {
            plan = try SafePastePlan.parse(text)
        } catch SafePastePlan.ParseError.singleLine {
            return true
        } catch SafePastePlan.ParseError.tooManyBytes {
            showPasteLimitAlert("The clipboard is larger than 5 MB.")
            return false
        } catch SafePastePlan.ParseError.tooManyLines {
            showPasteLimitAlert("The clipboard contains more than 10,000 lines.")
            return false
        } catch {
            NSSound.beep()
            return false
        }

        if pastePacer.isActive {
            cancelSafePaste(reason: .replaced)
        }
        presentSafePasteConfirmation(plan: plan, originalText: text)
        return false
    }

    func cancelSafePaste(reason: SafePastePacer.EndReason = .sessionEnded) {
        pastePacer.stop(reason: reason)
        hidePasteHUD()
        // A confirmation sheet abandoned by a tab close / reconnect must not
        // leave this stuck true (every later paste would just beep).
        pastePromptPresented = false
        // …and it must not still be able to SEND. Clearing the flag was all
        // this did: the sheet stayed on screen, its completion closure still
        // held the parsed plan, and clicking either send button afterwards
        // pushed the clipboard into whatever the tab had become. The
        // generation is what the closure checks; ending the sheet is so there
        // is nothing left to click, and so a second prompt cannot stack on top
        // of an abandoned one.
        pasteGeneration &+= 1
        if let prompt = pastePromptWindow, let parent = prompt.sheetParent {
            parent.endSheet(prompt, returnCode: .abort)
        }
        pastePromptWindow = nil
    }

    /// Ordinary typing cancels a running paste before its bytes are queued —
    /// the controller calls this from `TerminalViewDelegate.send`, which the
    /// pacer's own lines also go through (hence the flag).
    func prepareForOrdinaryUserInput() {
        keystrokePending = true
        if !sendingPacedLine, pastePacer.isActive {
            cancelSafePaste(reason: .keyboardInput)
        }
    }

    // MARK: - Command history (5.0 (1))

    /// The key this session files its history under (`CommandHistory.key`);
    /// nil = not recorded (a local shell). Set by `AppModel` when it opens
    /// the session.
    var historyKey: String?
    private var historyGate = HistoryEchoGate()
    /// Set by `prepareForOrdinaryUserInput` (a real keystroke, called just
    /// before its `send`) and consumed by the next `noteOutgoing`.
    private var keystrokePending = false

    /// Every `TerminalViewDelegate.send` calls this with its bytes. Records
    /// the line when the USER pressed Return: a key, not a paste, a snippet,
    /// a broadcast or Safe Paste's pacer (those never set `keystrokePending`).
    /// The line is read back from the screen row the cursor is on, the
    /// prompt cut off (`CommandHistoryCapture`) — keystrokes are not
    /// reconstructed, because Tab completion, `?` and line editing make that
    /// wrong on network gear. Anything doubtful is skipped.
    func noteOutgoing(_ bytes: [UInt8]) {
        let typed = keystrokePending
        keystrokePending = false
        guard historyKey != nil else { return }
        let counter = terminalView.terminal.changeCounter
        let isReturn = bytes == [0x0D] || bytes == [0x0D, 0x0A]
        if !isReturn {
            // Typed keys and pasted text leave the screen stale until their
            // echo arrives; a terminal reply (CSI …) says nothing.
            if typed || (bytes.first.map { $0 >= 0x20 && $0 != 0x7F } ?? false) {
                historyGate.typed(counter: counter)
            }
            return
        }
        let screenIsCurrent = historyGate.returned(counter: counter)
        guard typed, screenIsCurrent, let key = historyKey else { return }
        // A connection question is up: what is typed is the card's.
        guard !hasConnectionCard else { return }
        guard let command = commandOnCursorLine() else { return }
        AppModel.shared.historyStore.record(command, for: key)
    }

    private func commandOnCursorLine() -> String? {
        let terminal = terminalView.terminal
        guard !terminal.isAlternate else { return nil }
        let buffer = terminal.buffer
        var rows: [(text: String, wrapped: Bool)] = []
        rows.reserveCapacity(terminal.rows)
        for y in 0..<terminal.rows {
            let row = buffer.row(y)
            rows.append((row.string(trimRight: false), row.wrapped))
        }
        guard let line = CommandHistoryCapture.logicalLine(rows: rows, cursorRow: buffer.y) else { return nil }
        return CommandHistoryCapture.command(fromRow: line)
    }

    private func presentSafePasteConfirmation(plan: SafePastePlan, originalText: String) {
        let alert = SheepAlert()
        alert.alertStyle = .informational
        // A working dialog, landscape and one fixed size (the accessory's
        // 620 × 330), no icon — the user's call, 2026-10-09.
        alert.showsIcon = false
        alert.messageText = "Safe Multi-line Paste"
        let target = sessionLabel.map { " to \($0)" } ?? ""
        alert.informativeText = "Review all \(plan.lines.count) lines (\(Self.byteCountText(plan.sourceByteCount))) before sending\(target)."
        alert.addButton(withTitle: "Send Line by Line")
        alert.markCaution(alert.addButton(withTitle: "Paste Immediately"))
        alert.addButton(withTitle: "Cancel")

        let reviewLabel = NSTextField(labelWithString: "Commands to send:")
        reviewLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        let previewScrollView = NSScrollView(frame: .zero)
        previewScrollView.borderType = .bezelBorder
        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = true
        previewScrollView.autohidesScrollers = false
        previewScrollView.verticalScrollElasticity = .automatic
        previewScrollView.horizontalScrollElasticity = .automatic

        let previewTextView = NSTextView(frame: .zero)
        previewTextView.string = plan.lines.joined(separator: "\n")
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.isRichText = false
        previewTextView.allowsUndo = false
        previewTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        previewTextView.textColor = .labelColor
        previewTextView.backgroundColor = .textBackgroundColor
        previewTextView.textContainerInset = NSSize(width: 6, height: 6)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = true
        previewTextView.minSize = .zero
        previewTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.textContainer?.widthTracksTextView = false
        previewScrollView.documentView = previewTextView

        let delayLabel = NSTextField(labelWithString: "Delay between lines:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for milliseconds in Self.pasteDelayChoices {
            popup.addItem(withTitle: Self.delayTitle(milliseconds))
            popup.lastItem?.representedObject = milliseconds
        }
        let saved = UserDefaults.standard.integer(forKey: Self.pasteDelayKey)
        let selected = Self.pasteDelayChoices.contains(saved) ? saved : 200
        if let index = Self.pasteDelayChoices.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        popup.toolTip = "Time allowed for the device CLI to process each command"

        let delayControls = NSStackView(views: [delayLabel, popup])
        delayControls.orientation = .horizontal
        delayControls.alignment = .centerY
        delayControls.spacing = 10

        let accessory = NSStackView(views: [reviewLabel, previewScrollView, delayControls])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 620, height: 330)
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewScrollView.widthAnchor.constraint(equalToConstant: 620),
            previewScrollView.heightAnchor.constraint(equalToConstant: 285),
        ])
        alert.accessoryView = accessory

        pastePromptPresented = true
        pasteGeneration &+= 1
        let generation = pasteGeneration
        let handleResponse = { [weak self, weak popup] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            // An answer to a prompt that has since been cancelled is not an
            // answer to anything. Without this the paste went ahead — see
            // `cancelSafePaste`.
            guard self.pasteGeneration == generation else { return }
            self.pastePromptPresented = false
            self.pastePromptWindow = nil
            switch response {
            case .alertFirstButtonReturn:
                let delay = popup?.selectedItem?.representedObject as? Int ?? 200
                UserDefaults.standard.set(delay, forKey: Self.pasteDelayKey)
                self.startSafePaste(plan: plan, delayMilliseconds: delay)
            case .alertSecondButtonReturn:
                self.sendImmediatePaste(originalText)
            default:
                break
            }
        }

        if let window = terminalView.window, window.attachedSheet == nil {
            pastePromptWindow = alert.window
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            // Application-modal: nothing else in this app runs while it is up,
            // so there is no window to end — the generation check still covers
            // a cancel that arrives from a background queue's hop to main.
            handleResponse(alert.sheepStyled().runModal())
        }
    }

    /// The clipboard holds text a session's device/program set (OSC 52) and
    /// nothing has been copied since. Asked every time, single line or not:
    /// `evil-cmd\n` is one line, and the newline runs it. Cancel is the
    /// default, so Return does not paste. Shares the Safe Paste prompt's
    /// bookkeeping (`pastePromptPresented`, `pasteGeneration`,
    /// `pastePromptWindow`), so `cancelSafePaste` tears this one down too.
    private func presentPlantedPasteConfirmation(_ text: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste text a session put on the clipboard?"
        alert.informativeText = "Set by a device or program (OSC 52), not by a copy."
        alert.addButton(withTitle: "Cancel")   // default, so Return cancels
        alert.addButton(withTitle: "Paste")

        let preview = NSTextField(wrappingLabelWithString: PlantedClipboard.preview(text))
        preview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        preview.textColor = .labelColor
        preview.isSelectable = false
        preview.maximumNumberOfLines = 6
        preview.lineBreakMode = .byCharWrapping
        preview.preferredMaxLayoutWidth = 280
        preview.frame = NSRect(x: 0, y: 0, width: 280, height: 0)
        preview.setFrameSize(NSSize(width: 280, height: preview.fittingSize.height))
        alert.accessoryView = preview

        pastePromptPresented = true
        pasteGeneration &+= 1
        let generation = pasteGeneration
        let handleResponse = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, self.pasteGeneration == generation else { return }
            self.pastePromptPresented = false
            self.pastePromptWindow = nil
            guard response == .alertSecondButtonReturn else { return }
            // Next turn of the run loop: the sheet must be gone before Safe
            // Paste (a multi-line text still gets its own review) can put one
            // up. A cancel or a newer prompt in between bumps the generation.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pasteGeneration == generation, !self.pastePromptPresented else { return }
                self.plantedPasteConfirmed = true
                self.terminalView.pasteText(text)
                self.plantedPasteConfirmed = false
            }
        }

        if let window = terminalView.window, window.attachedSheet == nil {
            pastePromptWindow = alert.window
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.sheepStyled().runModal())
        }
    }

    private func startSafePaste(plan: SafePastePlan, delayMilliseconds: Int) {
        showPasteHUD(sent: 0, total: plan.lines.count, delayMilliseconds: delayMilliseconds)
        pastePacer.start(
            plan: plan,
            delayMilliseconds: delayMilliseconds,
            send: { [weak self] bytes in
                guard let self else { return false }
                // Through the view, so the bytes take exactly the path a
                // keystroke takes (delegate → worker.write). The flag is what
                // stops `prepareForOrdinaryUserInput` reading them as typing.
                self.sendingPacedLine = true
                self.terminalView.send(bytes, keystroke: false)
                self.sendingPacedLine = false
                // No hook installed means no worker that can refuse a write,
                // so the hand-over stands.
                return self.takeLastSendAccepted?() ?? true
            },
            progress: { [weak self] sent, total in
                self?.showPasteHUD(sent: sent, total: total, delayMilliseconds: delayMilliseconds)
            },
            completion: { [weak self] reason, sent in
                guard let self else { return }
                self.hidePasteHUD()
                // A paste that was cut short must SAY so. The pacer counts
                // lines it handed to the transport, so a silent stop left the
                // HUD reporting a complete send while the device had received
                // a config with holes in the middle.
                // The same goes for a session that ended or a tab switched
                // away mid-paste: the switch is half-configured either way.
                if reason == .inputDiscarded || (reason == .sessionEnded && sent < plan.lines.count) {
                    // Deferred: this completion can run inside SwiftUI's
                    // `dismantleNSView` (tab switch), where a modal must not spin.
                    DispatchQueue.main.async { [weak self] in
                        self?.reportPasteInterrupted(sent: sent, total: plan.lines.count, reason: reason)
                    }
                }
            }
        )
    }

    private func reportPasteInterrupted(sent: Int, total: Int, reason: SafePastePacer.EndReason) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste stopped part-way"
        let cause = reason == .inputDiscarded
            ? "The session stopped accepting input"
            : "The session ended or the tab was switched away"
        alert.informativeText = """
            \(cause) after \(sent) of \(total) lines, \
            so the rest was not sent. Check what actually reached the device \
            before pasting the remainder.
            """
        alert.addButton(withTitle: "OK")
        if let window = terminalView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.sheepStyled().runModal()
        }
    }

    /// "Paste Immediately": hand the text back to the view, which brackets it
    /// when the program asked for bracketed paste and turns newlines into CR.
    private func sendImmediatePaste(_ text: String) {
        pastingImmediately = true
        terminalView.pasteText(text)
        pastingImmediately = false
    }

    private func showPasteLimitAlert(_ detail: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = "Safe Paste Limit"
        alert.informativeText = detail + " Split it into smaller sections before sending."
        alert.addButton(withTitle: "OK")
        if let window = terminalView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.sheepStyled().runModal()
        }
    }

    private func showPasteHUD(sent: Int, total: Int, delayMilliseconds: Int) {
        if pasteHUD == nil {
            let hud = NSVisualEffectView()
            hud.material = .hudWindow
            hud.state = .active
            hud.blendingMode = .withinWindow
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 7
            hud.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pasteProgressLabel = label

            let stop = NSButton(title: "Stop", target: self, action: #selector(stopSafePasteFromHUD))
            stop.bezelStyle = .rounded
            stop.controlSize = .small
            stop.toolTip = "Stop before sending the next line"

            let stack = NSStackView(views: [label, stop])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            hud.addSubview(stack)
            terminalView.addSubview(hud)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: hud.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -6),
                hud.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 10),
                hud.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -12),
                hud.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            ])
            pasteHUD = hud
        }
        pasteProgressLabel?.stringValue = "Safe Paste \(sent)/\(total) · \(Self.delayTitle(delayMilliseconds))"
        pasteHUD?.isHidden = false
    }

    private func hidePasteHUD() {
        pasteHUD?.isHidden = true
    }

    @objc private func stopSafePasteFromHUD() {
        cancelSafePaste(reason: .stopped)
    }

    private static func delayTitle(_ milliseconds: Int) -> String {
        milliseconds >= 1_000 ? "\(milliseconds / 1_000) s" : "\(milliseconds) ms"
    }

    private static func byteCountText(_ count: Int) -> String {
        if count < 1_024 { return "\(count) bytes" }
        return String(format: "%.1f KB", Double(count) / 1_024)
    }
}
