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

    private static let pasteDelayKey = "safePasteDelayMilliseconds"
    /// Bumped by every prompt AND every cancel, so a stale sheet's answer can
    /// be told from the live one's.
    private var pasteGeneration = 0
    private weak var pastePromptWindow: NSWindow?
    private static let pasteDelayChoices = [50, 100, 200, 300, 500, 1_000]

    init(safePaste: Bool) {
        safePasteAvailable = safePaste
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480),
                                    cols: 80, rows: 24,
                                    scrollback: SessionTerminalHost.scrollbackLines)
        scrollerFader.attach(in: terminalView)
    }

    // MARK: - SafePaste

    /// `TerminalViewDelegate.shouldPaste`: true lets the view paste normally,
    /// false means this host has taken the text over.
    func shouldPaste(_ text: String) -> Bool {
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
        if !sendingPacedLine, pastePacer.isActive {
            cancelSafePaste(reason: .keyboardInput)
        }
    }

    private func presentSafePasteConfirmation(plan: SafePastePlan, originalText: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Safe Multi-line Paste"
        alert.informativeText = "Review all \(plan.lines.count) lines (\(Self.byteCountText(plan.sourceByteCount))) before sending."
        alert.addButton(withTitle: "Send Line by Line")
        alert.addButton(withTitle: "Paste Immediately")
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
        let alert = NSAlert()
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
        let alert = NSAlert()
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
