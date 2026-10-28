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

    /// Whether the session's worker has put every byte it accepted on the
    /// line (serial / telnet controllers: `!worker.hasUnsentWrites`). Safe
    /// Paste's line delay starts only then (`PaceSchedule`). nil = always
    /// drained (SSH, local).
    var lineDrained: (() -> Bool)?
    /// The line's speed (serial controller: the open port's baud), for Safe
    /// Paste's drain cap (`PaceSchedule.drainCap`). nil = unknown (telnet).
    var lineBaud: (() -> Int?)?

    private let scrollerFader = ScrollerFader()
    private let pastePacer = SafePastePacer()
    private var pastePromptPresented = false
    private var pasteHUD: NSVisualEffectView?
    private var pasteProgressLabel: NSTextField?
    private var pasteStopButton: NSButton?
    /// What the HUD's Stop does right now.
    private var hudStop: (() -> Void)?
    private var hudIsPaste = false
    private var sendingPacedLine = false
    /// Set while `sendImmediatePaste` calls back into the view, so the view's
    /// `shouldPaste` veto does not re-enter the SafePaste flow.
    private var pastingImmediately = false
    /// Set around `sendCommand`: the text is the app's, not the clipboard's.
    private var sendingCommand = false
    /// The command's Return (`CommandSendPlan.split`), for a review that
    /// takes its body over (`CommandSendPlan.reviewed`).
    private var sendingCommandReturn = false
    /// Set around a `sendCommand(confirmed: true)`: its paste is not asked
    /// about again.
    private var guardConfirmedSend = false
    /// Set by `shouldPaste` when Safe Paste sent a one-line body's CLEANED
    /// text itself during a `sendCommand`: that send's acceptance
    /// (`CommandSendPlan.bodyAccepted`).
    private var commandCleanedSend: Bool?

    /// Send text the app composed (Snippets, Broadcast) the way a paste
    /// reaches the device, minus the planted-clipboard question. Returns
    /// whether it went out now (false = Safe Paste took it for its own
    /// question, or the session refused it).
    ///
    /// `confirmed`: the user already said yes to a dangerous line (Broadcast
    /// asks once for every tab), so this tab does not ask again.
    @discardableResult
    func sendCommand(_ text: String, confirmed: Bool = false) -> Bool {
        // Body pasted, Return as its own CR (`CommandSendPlan`): inside a
        // bracketed paste the CR would not run the command. A veto (Safe
        // Paste reviews the body) sends no extra: the review sends the
        // command's Return, or none, itself (`CommandSendPlan.reviewed`).
        // Nothing overtakes a held Return or an open question, and nothing
        // goes on a line a file transfer owns (review 5.0 (22)).
        guard !inputBlocked else { NSSound.beep(); return false }
        let plan = CommandSendPlan.split(text)
        // One dangerous line that would run: ask in the tab first. Several
        // lines go through `shouldPaste`, whose review marks them.
        if !confirmed, safePasteAvailable, AppModel.shared.confirmDangerousCommands, plan.thenReturn,
           !plan.body.contains(where: \.isNewline), CommandGuard.isDangerous(plan.body, vendor: vendor) {
            askAboutCommand(plan.body) { [weak self] send in
                if send { self?.sendCommand(text, confirmed: true) }
            }
            return false
        }
        sendingCommand = true
        sendingCommandReturn = plan.thenReturn
        guardConfirmedSend = confirmed
        defer { sendingCommand = false; sendingCommandReturn = false; guardConfirmedSend = false }
        guard !plan.body.isEmpty else {
            if plan.thenReturn { terminalView.send(CommandSendPlan.returnKey, keystroke: false) }
            return plan.thenReturn
        }
        commandCleanedSend = nil
        let handedOver = terminalView.pasteText(plan.body)
        // The worker may still have refused the body (queue full, session
        // gone): then its Return must not follow, and Broadcast must not
        // count this tab (`CommandSendPlan.returnFollows`). A body Safe
        // Paste sent cleaned in the view's place counts by that send.
        let cleanedSend = commandCleanedSend
        commandCleanedSend = nil
        let accepted = CommandSendPlan.bodyAccepted(handedOver: handedOver, cleanedSend: cleanedSend,
                                                    lastSendAccepted: { takeLastSendAccepted?() ?? true })
        guard accepted else { return false }
        if CommandSendPlan.returnFollows(thenReturn: plan.thenReturn, bodyAccepted: accepted) {
            terminalView.send(CommandSendPlan.returnKey, keystroke: false)
        }
        return true
    }

    /// The AI panel's "Paste into Tab" (`AIPasteRoute`): one line is typed
    /// with no Return; several lines ALWAYS get the Safe Paste review — in
    /// every tab kind, whatever the Safe Paste setting — with no "Paste
    /// Immediately", and the last line is left typed without its CR. The
    /// model can never run anything; the user presses Return.
    @discardableResult
    func pasteFromAI(_ code: String) -> Bool {
        guard !inputBlocked else { NSSound.beep(); return false }
        switch AIPasteRoute.route(code) {
        case .empty:
            return false
        case .typeLine(let line):
            // One line, no line break: nothing to review and nothing runs.
            pastingImmediately = true
            defer { pastingImmediately = false }
            return terminalView.pasteText(line)
        case .review(let plan):
            guard !pastePromptPresented else { NSSound.beep(); return false }
            let dangerous = AppModel.shared.confirmDangerousCommands ? CommandGuard.dangerousLines(plan.lines, vendor: vendor) : []
            presentSafePasteConfirmation(CommandSendPlan.reviewed(plan, text: plan.lines.joined(separator: "\n"), thenReturn: nil),
                                         allowImmediate: false, dangerous: dangerous)
            return false
        case .refused(let error):
            showPasteLimitAlert(error == .tooManyLines ? String(localized: "The block contains more than 10,000 lines.") : String(localized: "The block is larger than 5 MB."))
            return false
        }
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
    private static let pasteDelayChoices = SafePastePlan.delayChoices
    /// The Safe Paste sheet's list (and so its subtitle) width.
    private static let pasteListWidth: CGFloat = 620

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
    private var pageTryAgain: (() -> Void)?

    /// The pane is smaller than this: the card goes to a panel instead (the
    /// card never shrinks its font or its width).
    private static let cardMargin = ConnectionCardPlan.cardMargin

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
        pageTryAgain = nil
        card.show(stage: stage, page: .progress(text)) { [weak self] action in self?.cardAction(action) }
        placeConnectionCard()
    }

    /// One of the worker's questions. `completion` is called exactly once:
    /// with the user's answer, or `.cancel` on Escape / Close, when a newer
    /// page replaces it, or when the card is taken down (tab closed).
    func presentPrompt(_ prompt: ConnectionPrompt, header: ConnectionCardHeader,
                       onCancelAfterAnswer: (() -> Void)? = nil,
                       completion: @escaping (ConnectionPromptReply) -> Void) {
        beginConnectionCard(header)
        guard let card = connectionCard else { completion(.cancel); return }
        settleQuestion(.cancel)
        pageClose = nil
        pageKnownHosts = nil
        pageTryAgain = nil
        questionCompletion = completion
        card.show(stage: prompt.stage, page: .question(prompt), busyCancel: onCancelAfterAnswer) { [weak self] action in self?.cardAction(action) }
        placeConnectionCard()
    }

    /// The connection failed: the reason in red on the card, at the stage it
    /// got to. `onKnownHosts` adds "Open Known Hosts…", `onTryAgain` adds
    /// "Try Again" (the default — Return).
    func showConnectionFailure(title: String, message: String, hostKeyProblem: Bool,
                               onKnownHosts: (() -> Void)?, onTryAgain: (() -> Void)? = nil,
                               onClose: @escaping () -> Void) {
        guard let card = connectionCard else { return }
        settleQuestion(.cancel)
        pageClose = onClose
        pageKnownHosts = onKnownHosts
        pageTryAgain = onTryAgain
        let plan = ConnectionCardPlan.failure(at: card.stage, offersKnownHosts: onKnownHosts != nil,
                                              offersTryAgain: onTryAgain != nil)
        card.show(stage: plan.stage,
                  page: .failure(title: title, message: message, hostKeyProblem: hostKeyProblem,
                                 plan: plan)) { [weak self] action in self?.cardAction(action) }
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
        pageTryAgain = nil
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
        case .tryAgain:
            // Once: the session is replaced by a new one.
            let tryAgain = pageTryAgain
            pageTryAgain = nil
            pageClose = nil
            tryAgain?()
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
        let fits = ConnectionCardPlan.cardFits(card: needed, in: size)
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
        // Nothing lands between two paced lines (`PacedRunGate`) — in every
        // tab kind, before any early "paste as before".
        guard PacedRunGate.verdict(.paste, runActive: pastePacer.isActive) != .refuse else {
            NSSound.beep()
            return false
        }
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
        guard safePasteAvailable, !pastingImmediately else { return true }
        // Before any early "paste as before": a paste must not overtake a
        // held Return, land under an open question, or hit a transfer.
        guard !inputBlocked else {
            NSSound.beep()
            return false
        }
        // Confirm Dangerous Commands looks at every paste, Safe Paste on or
        // off — but with Safe Paste off it only ever ADDS a question for a
        // dangerous line; everything else pastes exactly as before.
        let guardOn = AppModel.shared.confirmDangerousCommands && !guardConfirmedSend
        let reviewAll = AppModel.shared.safePasteEnabled
        guard reviewAll || guardOn else { return true }
        guard !pastePromptPresented else {
            NSSound.beep()
            return false
        }

        // What goes out is the CLEANED text (`PasteHygiene`): escape
        // sequences, controls and bidi marks out, U+2028/U+2029/NEL as line
        // breaks — so the review's lines, its count and its red marks are
        // exactly what is sent (6.0 (12)).
        let cleanText = PasteHygiene.cleaned(text)
        let plan: SafePastePlan
        do {
            plan = try SafePastePlan.parseClipboard(text)
        } catch SafePastePlan.ParseError.singleLine {
            // One line runs only when it carries its own line break; without
            // one the user's Return is checked like any typed line.
            let line = cleanText.trimmingCharacters(in: .newlines)
            guard guardOn, line != cleanText, CommandGuard.isDangerous(line, vendor: vendor) else {
                // Safe Paste on: one line still goes out clean (an ESC or a
                // NUL in it would reach the device unseen).
                guard reviewAll, cleanText != text else { return true }
                let sent = !cleanText.isEmpty && sendImmediatePaste(cleanText)
                // The view's copy is vetoed (false) but the cleaned text went
                // out: a command's Return must still follow it.
                if sendingCommand { commandCleanedSend = sent }
                return false
            }
            askAboutCommand(line) { [weak self] send in
                if send { self?.sendImmediatePaste(cleanText) }
            }
            return false
        } catch _ where !reviewAll {
            return true
        } catch SafePastePlan.ParseError.tooManyBytes {
            showPasteLimitAlert(String(localized: "The clipboard is larger than 5 MB."))
            return false
        } catch SafePastePlan.ParseError.tooManyLines {
            showPasteLimitAlert(String(localized: "The clipboard contains more than 10,000 lines."))
            return false
        } catch {
            NSSound.beep()
            return false
        }

        let dangerous = guardOn ? CommandGuard.dangerousLines(plan.lines, vendor: vendor) : []
        guard reviewAll || !dangerous.isEmpty else { return true }
        // A snippet's body: the review sends its Return, or none (bug: the
        // last line lost or gained one).
        let reviewed = CommandSendPlan.reviewed(plan, text: cleanText, thenReturn: sendingCommand ? sendingCommandReturn : nil)
        presentSafePasteConfirmation(reviewed, dangerous: dangerous)
        return false
    }

    func cancelSafePaste(reason: SafePastePacer.EndReason = .sessionEnded) {
        // The session is gone or refuses input: a held Return (and its
        // question) has nothing left to go to.
        if reason == .sessionEnded || reason == .inputDiscarded { cancelCommandGuard() }
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
        if PacedRunGate.verdict(sendingPacedLine ? .pacedLine : .keystroke, runActive: pastePacer.isActive) == .stopRun {
            cancelSafePaste(reason: .keyboardInput)
        }
    }

    /// A paced Safe Paste is still sending (Send File via XMODEM waits for it).
    var isPacingPaste: Bool { pastePacer.isActive }

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
        if typed { typedLine.typed(bytes) } else { typedLine.sent(bytes) }
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
        cursorLine().flatMap(CommandHistoryCapture.command(fromRow:))
    }

    /// The logical line the cursor is on (soft wraps joined); nil on the
    /// alternate screen.
    private func cursorLine() -> String? {
        let terminal = terminalView.terminal
        guard !terminal.isAlternate else { return nil }
        let buffer = terminal.buffer
        var rows: [(text: String, wrapped: Bool)] = []
        rows.reserveCapacity(terminal.rows)
        for y in 0..<terminal.rows {
            let row = buffer.row(y)
            rows.append((row.string(trimRight: false), row.wrapped))
        }
        return CommandHistoryCapture.logicalLine(rows: rows, cursorRow: buffer.y)
    }

    // MARK: - Confirm Dangerous Commands (5.0 (22))

    /// The session's device family (`Host.highlightVendor`), set by the
    /// controller: Linux/Gaia-only rules (`shutdown`, `halt`) need it.
    var guardVendor: (() -> Vendor)?
    /// What the keys since the last Return spell (`TypedLine`).
    private var typedLine = TypedLine()
    /// The held Return and every key typed behind it, in order. Non-empty
    /// exactly while a Return is held (waiting for the echo, or asking).
    private var heldKeys: [[UInt8]] = []
    /// Set while held keys go back through the view: they pass the gate.
    private var releasingHeld = false
    /// Bumped by every hold and every drop: a stale echo timer is ignored.
    private var guardGeneration = 0
    private var guardCard: CommandGuardCardView?
    private var guardOverlay: ConnectionOverlayView?
    private weak var guardSheet: NSWindow?

    /// How long a Return waits for the echo before the screen is read as
    /// it stands (a satellite link is slower than this; the rules accept
    /// abbreviations, so a half-echoed `rel` already counts).
    private static let echoWait: TimeInterval = 0.4
    /// The echo is "in" once the screen has been quiet this long.
    private static let echoQuiet: TimeInterval = 0.05

    /// SSH and serial only (a device CLI), and never under a connection
    /// card or a full-screen program.
    private var commandGuardActive: Bool {
        safePasteAvailable && AppModel.shared.confirmDangerousCommands
            && !hasConnectionCard && !terminalView.terminal.isAlternate
    }

    private var vendor: Vendor { guardVendor?() ?? .auto }

    /// A Return is held and nothing may overtake it.
    var isHoldingReturn: Bool { !heldKeys.isEmpty }

    /// A Safe Paste paced run is starting (serial tabs: the wrong-speed
    /// detector starts over — `ConsoleBaudGuess.Detector.feed`).
    var onPacedRunStart: (() -> Void)?
    /// The serial controller's "a file transfer owns the line" (XMODEM).
    var lineBusy: (() -> Bool)?

    /// Pastes, snippets and the AI's paste are refused: a Return is held, a
    /// dangerous-command question is open, a transfer owns the line, or a
    /// paced Safe Paste is still sending (`PacedRunGate`).
    var inputBlocked: Bool {
        isHoldingReturn || guardCard != nil || guardSheet != nil || (lineBusy?() ?? false)
            || PacedRunGate.verdict(.paste, runActive: pastePacer.isActive) == .refuse
    }

    /// A key the controller refused itself (a transfer owns the line): the
    /// flag `userTyped` set must not make the NEXT send look typed.
    func discardPendingKeystroke() {
        keystrokePending = false
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Called by the controller's `send` BEFORE the worker gets the bytes:
    /// false = held here, write nothing. Only a Return the user TYPED is
    /// ever held; a paste, a snippet, Safe Paste's lines and the terminal's
    /// own replies always pass (the paste paths ask on their own).
    func admitOutgoing(_ bytes: [UInt8]) -> Bool {
        if releasingHeld { return true }
        let typed = keystrokePending
        if isHoldingReturn {
            // Keys typed while a Return waits wait behind it — never ahead.
            guard typed else { return true }
            keystrokePending = false
            heldKeys.append(bytes)
            return false
        }
        // A question is up but the terminal still has the keyboard (the card
        // takes it a turn later): keys wait for the answer, they do not go
        // to the device under it — and a Return here must not start a hold
        // nothing would ever resume.
        if typed, guardCard != nil || guardSheet != nil {
            keystrokePending = false
            NSSound.beep()
            return false
        }
        // ⌃J (LF) runs the line too on IOS, VRP and a shell.
        guard typed, HeldKeys.isReturn(bytes), commandGuardActive else { return true }
        let row = cursorLine()
        // A login/password prompt: what was typed is an answer, not a command.
        if let row, CommandHistoryFilter.looksLikeCredentialPrompt(row) { return true }
        let screen = row.flatMap { CommandHistoryCapture.split(row: $0) }
        let current = historyGate.isCurrent(counter: terminalView.terminal.changeCounter)
        switch CommandGuard.onReturn(typed: typedLine.text, screen: screen, screenIsCurrent: current, vendor: vendor) {
        case .send:
            return true
        case .ask(let command):
            keystrokePending = false
            hold(bytes)
            askAboutHeldReturn(command)
            return false
        case .waitForEcho:
            keystrokePending = false
            hold(bytes)
            waitForEcho(generation: guardGeneration, started: Self.uptime(), lastCounter: terminalView.terminal.changeCounter,
                        lastChange: nil)
            return false
        }
    }

    private func hold(_ bytes: [UInt8]) {
        guardGeneration &+= 1
        heldKeys = [bytes]
    }

    /// Polls the screen until it has changed and then gone quiet (the echo
    /// is in), or the wait runs out; then the screen decides.
    private func waitForEcho(generation: Int, started: TimeInterval, lastCounter: UInt64, lastChange: TimeInterval?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.guardGeneration == generation, self.isHoldingReturn, self.guardCard == nil,
                  self.guardSheet == nil else { return }
            let counter = self.terminalView.terminal.changeCounter
            // Monotonic: a wall-clock step back must not stretch the wait.
            let now = Self.uptime()
            let changed = counter != lastCounter ? now : lastChange
            let quiet = changed.map { now - $0 >= Self.echoQuiet } ?? false
            guard quiet || now - started >= Self.echoWait else {
                self.waitForEcho(generation: generation, started: started, lastCounter: counter, lastChange: changed)
                return
            }
            let row = self.cursorLine()
            let screen = row.flatMap { CommandHistoryCapture.split(row: $0) }
            switch CommandGuard.afterEcho(screen: screen, vendor: self.vendor) {
            case .ask(let command) where self.commandGuardActive:
                self.askAboutHeldReturn(command)
            default:
                self.releaseHeld()
            }
        }
    }

    /// Sends the held Return and the keys behind it, in order, as the keys
    /// they were (history records the line as usual). Only up to the first
    /// Return pass unchecked (`HeldKeys.release`): the rest are typed again
    /// through the gate, so a dangerous line behind it is held in its turn —
    /// and since held keys never reached `noteOutgoing`, `typedLine` spells
    /// that line from these sends.
    private func releaseHeld() {
        let keys = HeldKeys.release(heldKeys)
        heldKeys = []
        guardGeneration &+= 1
        releasingHeld = true
        for key in keys.now { terminalView.send(key, keystroke: true) }
        releasingHeld = false
        for key in keys.again { terminalView.send(key, keystroke: true) }
    }

    /// Drops the held Return and the keys behind it; the command stays
    /// typed on the device's line, which the keys no longer spell.
    private func dropHeld() {
        guard isHoldingReturn else { return }
        heldKeys = []
        guardGeneration &+= 1
        typedLine.other()
    }

    /// Takes the question down and drops what it held (tab closed, session
    /// ended). `turnedOff`: the user switched the guard off — a Return still
    /// only waiting for its echo (nobody was asked anything) goes out as
    /// typed; one under a question is dropped like a Cancel.
    func cancelCommandGuard(turnedOff: Bool = false) {
        if turnedOff, isHoldingReturn, guardCard == nil, guardSheet == nil {
            releaseHeld()
            return
        }
        closeGuardQuestion()
        dropHeld()
    }

    private func askAboutHeldReturn(_ command: String) {
        askAboutCommand(command) { [weak self] send in
            guard let self else { return }
            if send { self.releaseHeld() } else { self.dropHeld() }
        }
    }

    /// The card over the pane — or, in a pane too small to hold it, a sheet
    /// on the window. `completion(true)` = Send.
    private func askAboutCommand(_ command: String, completion: @escaping (Bool) -> Void) {
        // A connection card is up (still logging in): a snippet or a paste
        // has nothing to run on yet, and a second card over the first
        // could not be answered — refuse it, nothing is sent.
        guard !hasConnectionCard else {
            NSSound.beep()
            completion(false)
            return
        }
        closeGuardQuestion()
        let title = sessionLabel ?? String(localized: "this session")
        let card = CommandGuardCardView(title: title, command: command)
        let size = card.fittingCardSize
        let bounds = terminalView.bounds.size
        guard terminalView.window != nil, bounds.width >= size.width + Self.cardMargin,
              bounds.height >= size.height + Self.cardMargin else {
            askInSheet(title: title, command: command, completion: completion)
            return
        }
        let hadKeyboard = terminalView.window?.firstResponder === terminalView
        let overlay = ConnectionOverlayView(frame: terminalView.bounds)
        overlay.onVeilClick = { [weak card] in card?.takeKeyboard() }
        terminalView.addSubview(overlay)
        overlay.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        card.onAnswer = { [weak self] send in
            self?.closeGuardQuestion()
            completion(send)
        }
        guardCard = card
        guardOverlay = overlay
        if hadKeyboard { card.takeKeyboard() }
    }

    private func askInSheet(title: String, command: String, completion: @escaping (Bool) -> Void) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = command
        alert.addButton(withTitle: String(localized: "Cancel"))   // default: Return cancels
        alert.addButton(withTitle: String(localized: "Send")).hasDestructiveAction = true
        let generation = guardGeneration
        if let window = terminalView.window, window.attachedSheet == nil {
            guardSheet = alert.window
            alert.beginSheetModal(for: window) { [weak self] response in
                // `closeGuardQuestion` clears `guardSheet` before it ends the
                // sheet: an answer to a question taken down is to nothing.
                guard let self, self.guardSheet != nil, self.guardGeneration == generation else { return }
                self.guardSheet = nil
                completion(response == .alertSecondButtonReturn)
            }
        } else {
            let response = alert.sheepStyled().runModal()
            guard guardGeneration == generation else { return }
            completion(response == .alertSecondButtonReturn)
        }
    }

    private func closeGuardQuestion() {
        if let card = guardCard {
            let hadKeyboard = card.hasKeyboard
            card.onAnswer = nil
            guardCard = nil
            card.removeFromSuperview()
            guardOverlay?.removeFromSuperview()
            guardOverlay = nil
            if hadKeyboard { terminalView.window?.makeFirstResponder(terminalView) }
        }
        if let sheet = guardSheet {
            guardSheet = nil
            sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
        }
    }

    /// The keyboard came back to the terminal while the card is up: the
    /// card takes it (next turn, as the connection card does).
    func terminalTookKeyboardForGuard() {
        guard guardCard != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let card = self.guardCard,
                  self.terminalView.window?.firstResponder === self.terminalView else { return }
            card.takeKeyboard()
        }
    }

    private func presentSafePasteConfirmation(_ reviewed: CommandSendPlan.Reviewed, allowImmediate: Bool = true,
                                              dangerous: [Int] = []) {
        let plan = reviewed.plan
        let alert = SheepAlert()
        alert.alertStyle = .informational
        // A working dialog, landscape and one fixed size (the accessory's
        // 620 pt list), no icon — the user's call, 2026-10-09.
        alert.showsIcon = false
        alert.messageText = String(localized: "Safe Multi-line Paste")
        let size = Self.byteCountText(plan.sourceByteCount)
        // ONE line, as wide as the list (the user, 6.0 (12)): a long session
        // name is cut in the middle to fit, the sentence never wraps.
        let subtitleFont = NSFont.systemFont(ofSize: 12)
        let sentence: (String?) -> String = { name in
            name.map { String(localized: "Review all \(plan.lines.count) lines (\(size)) before sending to \($0).") }
                ?? String(localized: "Review all \(plan.lines.count) lines (\(size)) before sending.")
        }
        let fittedName = sessionLabel.map { name in
            MiddleTruncation.fit(name) { candidate in
                // 12 pt less than the column: the label's cell pads its text,
                // and an overflow would let it cut a second time.
                ceil((sentence(candidate) as NSString).size(withAttributes: [.font: subtitleFont]).width) <= Self.pasteListWidth - 12
            }
        }
        alert.informativeText = sentence(fittedName)
        alert.informativeSingleLine = true
        alert.addButton(withTitle: String(localized: "Send Line by Line"))
        if allowImmediate { alert.markCaution(alert.addButton(withTitle: String(localized: "Paste Immediately"))) }
        alert.addButton(withTitle: String(localized: "Cancel"))

        let reviewLabel = NSTextField(labelWithString: String(localized: "Commands to send:"))
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
        if !dangerous.isEmpty, let storage = previewTextView.textStorage {
            // The lines Confirm Dangerous Commands found, in the card's red —
            // AFTER `textColor`, which recolours the whole text (the red never
            // showed until 6.0 (12)).
            let ranges = CommandGuard.lineRanges(plan.lines)
            storage.beginEditing()
            for index in dangerous where ranges.indices.contains(index) {
                storage.addAttribute(.foregroundColor, value: SheepAlert.destructiveRed, range: ranges[index])
            }
            storage.endEditing()
        }
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

        let delayLabel = NSTextField(labelWithString: String(localized: "Delay between lines:"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for milliseconds in Self.pasteDelayChoices {
            popup.addItem(withTitle: Self.delayTitle(milliseconds))
            popup.lastItem?.representedObject = milliseconds
        }
        let saved = UserDefaults.standard.integer(forKey: Self.pasteDelayKey)
        let selected = SafePastePlan.delay(saved: saved)
        if let index = Self.pasteDelayChoices.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        popup.toolTip = String(localized: "Time allowed for the device CLI to process each command")

        let delayControls = NSStackView(views: [delayLabel, popup])
        delayControls.orientation = .horizontal
        delayControls.alignment = .centerY
        delayControls.spacing = 10

        // "Commands to send:" with the dangerous-line note on its right, in
        // the card's red (it used to make the subtitle wrap). The words are
        // `CommandGuard.reviewNote`'s (shared with Windows, compared by the
        // harness).
        let headerViews: [NSView]
        if dangerous.isEmpty {
            headerViews = [reviewLabel]
        } else {
            let note = NSTextField(labelWithString: String(localized: "\(dangerous.count) of them can restart or erase the device."))
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            note.textColor = SheepAlert.destructiveRed
            note.alignment = .right
            note.lineBreakMode = .byTruncatingTail
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews = [reviewLabel, NSView(), note]
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        // .centerY, not .firstBaseline: the spacer NSView has no baseline,
        // and a baseline row with one asked Auto Layout for constraints it
        // could not all satisfy (6.0 (12) review).
        header.alignment = .centerY
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: Self.pasteListWidth).isActive = true

        let accessory = NSStackView(views: [header, previewScrollView, delayControls])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewScrollView.widthAnchor.constraint(equalToConstant: Self.pasteListWidth),
            previewScrollView.heightAnchor.constraint(equalToConstant: 285),
        ])
        // The frame SheepAlert pins is the content's OWN height (label + 8 +
        // the 285 pt list + 8 + the delay row ≈ 340). A fixed 330 was too
        // short: Auto Layout broke a constraint and the column centred its
        // rows, leaving empty space above the title (6.0 (12)).
        accessory.frame = NSRect(x: 0, y: 0, width: Self.pasteListWidth, height: ceil(accessory.fittingSize.height))
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
                let delay = popup?.selectedItem?.representedObject as? Int ?? SafePastePlan.delayDefault
                UserDefaults.standard.set(delay, forKey: Self.pasteDelayKey)
                self.startSafePaste(plan: plan, delayMilliseconds: delay)
            case .alertSecondButtonReturn where allowImmediate:
                // A command's Return, outside the paste (`sendCommand`).
                if CommandSendPlan.returnFollows(thenReturn: reviewed.immediateReturn,
                                                 bodyAccepted: self.sendImmediatePaste(reviewed.immediateText)) {
                    self.terminalView.send(CommandSendPlan.returnKey, keystroke: false)
                }
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
        alert.messageText = String(localized: "Paste text a session put on the clipboard?")
        alert.informativeText = String(localized: "Set by a device or program (OSC 52), not by a copy.")
        alert.addButton(withTitle: String(localized: "Cancel"))   // default, so Return cancels
        alert.addButton(withTitle: String(localized: "Paste"))

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
        // The paced run's HUD takes the top-right corner the wrong-speed
        // hint uses (serial tabs): the hint goes, the detector starts over.
        hideBaudHint()
        onPacedRunStart?()
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
            drained: { [weak self] in self?.lineDrained?() ?? true },
            baud: lineBaud?(),
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
                if reason == .inputDiscarded || reason == .deviceNotTakingInput
                    || (reason == .sessionEnded && sent < plan.lines.count) {
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
        alert.messageText = String(localized: "Paste stopped part-way")
        let cause = switch reason {
        case .inputDiscarded:
            String(localized: "The session stopped accepting input after \(sent) of \(total) lines, so the rest was not sent.")
        case .deviceNotTakingInput:
            // The last line is still waiting to leave (flow control held,
            // or the far end stopped reading) past `PaceSchedule.drainCap`.
            String(localized: "The device is not taking input (\(sent) of \(total) lines sent), so the rest was not sent.")
        default:
            String(localized: "The session ended or the tab was switched away after \(sent) of \(total) lines, so the rest was not sent.")
        }
        alert.informativeText = cause + " "
            + String(localized: "Check what actually reached the device before pasting the remainder.")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = terminalView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.sheepStyled().runModal()
        }
    }

    /// "Paste Immediately": hand the text back to the view, which brackets it
    /// when the program asked for bracketed paste and turns newlines into CR.
    @discardableResult
    private func sendImmediatePaste(_ text: String) -> Bool {
        pastingImmediately = true
        defer { pastingImmediately = false }
        // Handed over AND taken by the worker: a snippet's separate Return
        // after it goes out only then (`CommandSendPlan.returnFollows`).
        return terminalView.pasteText(text) && (takeLastSendAccepted?() ?? true)
    }

    private func showPasteLimitAlert(_ detail: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Safe Paste Limit")
        alert.informativeText = detail + " " + String(localized: "Split it into smaller sections before sending.")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = terminalView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.sheepStyled().runModal()
        }
    }

    private func showPasteHUD(sent: Int, total: Int, delayMilliseconds: Int) {
        showStatusHUD(String(localized: "Safe Paste \(sent)/\(total) · \(Self.delayTitle(delayMilliseconds))"),
                      stopHelp: String(localized: "Stop before sending the next line")) { [weak self] in
            self?.cancelSafePaste(reason: .stopped)
        }
        hudIsPaste = true
    }

    /// The small top-right HUD with a Stop button — Safe Paste's progress,
    /// and Send File via XMODEM's (5.0 (22)). One at a time: the transfer
    /// refuses input, so a paste cannot run beside it.
    func showStatusHUD(_ text: String, stopHelp: String, onStop: @escaping () -> Void) {
        hideBaudHint()
        hudStop = onStop
        hudIsPaste = false
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

            let stop = NSButton(title: String(localized: "Stop"), target: self, action: #selector(stopSafePasteFromHUD))
            stop.bezelStyle = .rounded
            stop.controlSize = .small
            pasteStopButton = stop

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
        pasteProgressLabel?.stringValue = text
        pasteStopButton?.toolTip = stopHelp
        pasteHUD?.isHidden = false
    }

    // MARK: - Wrong-speed hint (6.0 (12), serial tabs) — `BaudHintView`

    private var baudHint: BaudHintView?

    /// "Garbled? [Try rate] ×" top right, where the status HUD sits (one or
    /// the other: the HUD takes the corner). Replaces one already up.
    func showBaudHint(rate: Int, onTry: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hideBaudHint()
        // The corner is the status HUD's while it is up (`ConsoleBaudGuess.lineBusy`).
        guard !hasStatusHUD else { return }
        let hint = BaudHintView(rootView: BaudHintContent(rate: rate, onTry: onTry, onDismiss: onDismiss))
        hint.translatesAutoresizingMaskIntoConstraints = false
        terminalView.addSubview(hint)
        NSLayoutConstraint.activate([
            // popupChrome's 10 pt shadow room sits inside the view.
            hint.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 0),
            hint.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -2),
        ])
        baudHint = hint
    }

    func hideBaudHint() {
        baudHint?.removeFromSuperview()
        baudHint = nil
    }

    var hasBaudHint: Bool { baudHint != nil }
    /// The status HUD (paste progress / XMODEM) is on screen.
    var hasStatusHUD: Bool { pasteHUD.map { !$0.isHidden } ?? false }

    func hideStatusHUD() {
        hudStop = nil
        hudIsPaste = false
        pasteHUD?.isHidden = true
    }

    /// Only Safe Paste's own HUD: a transfer's must survive a cancelled
    /// paste (typing during a transfer is refused, and that cancels one).
    private func hidePasteHUD() {
        guard hudIsPaste else { return }
        hideStatusHUD()
    }

    @objc private func stopSafePasteFromHUD() {
        hudStop?()
    }

    private static func delayTitle(_ milliseconds: Int) -> String {
        milliseconds >= 1_000 ? String(localized: "\(milliseconds / 1_000) s") : String(localized: "\(milliseconds) ms")
    }

    private static func byteCountText(_ count: Int) -> String {
        if count < 1_024 { return String(localized: "\(count) bytes") }
        return String(format: "%.1f KB", Double(count) / 1_024)
    }
}
