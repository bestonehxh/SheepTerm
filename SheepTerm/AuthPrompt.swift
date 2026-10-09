import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The OLD application-modal panels for SSH questions — since 4.2 (9) only a
/// FALLBACK. Every question a session's worker asks (username, password,
/// challenge, first-seen host key) is a card inside the tab
/// (`ConnectionPromptView`, via `SessionTerminalHost.presentPrompt` and
/// `PromptBridge`) and nothing blocks the main thread. These panels run only
/// if a prompt is ever asked ON the main thread, where the card could not be
/// answered (main would be the thread waiting) — never the normal path. Do
/// not wire them back in as the normal path (ARCHITECTURE.md §15).
///
/// `forceASCIIKeyboard` is shared by every credential field in the app.
enum AuthPrompt {
    @MainActor
    static func ask(prompt: String, secure: Bool) -> String? {
        final class Box {
            var value: String?
        }
        let box = Box()

        // Force-switch the keyboard to an English-capable layout so a Thai
        // input source cannot swallow the first characters of a login. It is
        // a convenience, not a restriction: whatever ends up in the field is
        // sent unchanged.
        forceASCIIKeyboard()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }

        let root = AuthPromptView(prompt: prompt, secure: secure) { value in
            box.value = value
            NSApp.stopModal()
        }
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()

        NSApp.runModal(for: panel)
        // orderOut, NOT close() — and it is not a leak. Two things were
        // checked before leaving it this way:
        //   • ARC alone frees the panel here: nothing (NSApp.windows
        //     included) still holds an ordered-out window once the last
        //     strong reference goes out of scope, so the hosting view and
        //     the SwiftUI state holding what was typed die with this call.
        //   • close() would post the "last window closed" question. The app
        //     answers it with applicationShouldTerminateAfterLastWindowClosed
        //     == true, and a prompt CAN be the only window on screen: cancel
        //     a quit and the main window is already gone while the sessions
        //     live on, and the next auto-reconnect asks for a password from
        //     a windowless app. Closing that panel would offer to quit.
        panel.orderOut(nil)
        return box.value
    }

    /// First connection to a host — the main-thread fallback of the in-tab
    /// card (see the type's note). A glass panel (`HostKeyPromptView`), everything centred: the target,
    /// the key type and the fingerprint in two even lines. "Cancel" is the
    /// default button (Return) and Escape; trusting takes a deliberate click.
    /// Polls `isCancelled` while open: a tab closed (or the app quitting)
    /// underneath the dialog takes the dialog with it and answers `.stopped`,
    /// so the blocked worker is released and nothing is pinned.
    @MainActor
    static func confirmHostKey(_ question: SSHWorker.HostKeyQuestion,
                               isCancelled: @escaping @Sendable () -> Bool) -> SSHWorker.HostKeyAnswer {
        // The worker may have been stopped while this waited for main.
        if isCancelled() { return .stopped }
        final class Box { var trusted = false }
        let box = Box()

        // Everything shown went through the worker's sanitizer: the host is
        // the user's, but the key type is the server's.
        let fingerprint = SSHWorker.printable(question.fingerprint)
        let root = HostKeyPromptView(
            target: SSHWorker.printable(question.target),
            keyType: HostKeyPromptView.keyTypeLabel(SSHWorker.printable(question.keyType)),
            fingerprint: fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
        ) { trusted in
            box.trusted = trusted
            NSApp.stopModal()
        }
        // The same glass panel as the password prompt (`ask`) — see the
        // notes there on orderOut vs close.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()

        // Return and Escape both answer Cancel (keyCodes 36 Return, 76
        // keypad Enter, 53 Escape). Done here rather than with the view's
        // `.defaultAction`, which would paint Cancel blue — only Trust is
        // coloured.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard [36, 76, 53].contains(event.keyCode), event.window === panel else { return event }
            box.trusted = false
            NSApp.stopModal()
            return nil
        }
        // A tab closed (or the app quitting) underneath the panel takes the
        // panel with it. Scheduled in the modal run-loop mode, or it never
        // fires while the panel is up; it fires on the main run loop.
        let watch = Timer(timeInterval: 0.2, repeats: true) { _ in
            guard isCancelled() else { return }
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(watch, forMode: .modalPanel)
        NSApp.runModal(for: panel)
        watch.invalidate()
        if let escape { NSEvent.removeMonitor(escape) }
        panel.orderOut(nil)

        if isCancelled() { return .stopped }
        return box.trusted ? .trust : .cancel
    }

    @MainActor
    static func forceASCIIKeyboard() {
        if let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(source)
        }
    }
}

struct AuthPromptView: View {
    let prompt: String
    let secure: Bool
    let completion: (String?) -> Void

    @State private var text = ""
    @State private var focusTrigger = 0

    /// What the prompt answers with. A USERNAME is trimmed for the same
    /// reason the sheets trim theirs — " admin" pasted out of a runbook
    /// fails authentication and looks identical to a good one. A PASSWORD is
    /// never touched: a leading or trailing space can be part of it.
    private var answer: String {
        secure ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // NOT gated on an empty answer. It is tempting to disable "Continue" for
    // an empty non-secure answer (an empty username is useless, and SSHWorker
    // closes the session with "no username given" for it) — but this same
    // dialog also answers an ECHOED keyboard-interactive challenge, where an
    // empty answer can be the right one. The two are indistinguishable here:
    // both arrive as secure == false.

    var body: some View {
        VStack(spacing: 18) {
            SheepLockBadge()

            VStack(spacing: 4) {
                Text("SSH Authentication")
                    .font(.system(size: 15, weight: .semibold))
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PopupTextEntry(placeholder: secure ? "Password" : "Username", secure: secure, text: $text,
                           focusTrigger: focusTrigger) { completion(answer) }

            HStack(spacing: 10) {
                Button("Cancel") { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(secure ? "Connect" : "Continue") { completion(answer) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 350)
        .popupChrome()
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
            focusTrigger += 1
        }
    }
}

/// The popups' glass (AuthPromptView, HostKeyPromptView, the in-tab
/// connection card): rounded 24, ultra-thin material, a light top edge, 10 pt
/// of room for the shadow. One modifier so the three cannot drift apart.
extension View {
    func popupChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(10)
    }
}

/// The popups' text entry: icon, field and (for a secret) the reveal eye in
/// one rounded box that turns accent with the caret, plus the orange
/// non-ASCII warning. Used by AuthPromptView and by the in-tab card, so the
/// two are the same field. The focus is the caller's: bump `focusTrigger`
/// to put the caret here (the popup does it on appear; the card only when
/// its pane has the keyboard — never stealing it).
struct PopupTextEntry: View {
    let placeholder: String
    let secure: Bool
    @Binding var text: String
    var focusTrigger: Int
    /// Take the caret as soon as the field exists (a page that replaced one
    /// that had the keyboard — `focusTrigger` cannot say it: the new view is
    /// born with the current value, so it never sees a change).
    var focusOnAppear = false
    let onSubmit: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @State private var revealed = false
    /// Revealing swaps SecureField for TextField — two different views, so
    /// they cannot share one focus binding: the focus set on the old field
    /// dies with it and the caret vanishes (you type into nothing). Each
    /// field claims its own value instead, and the eye button re-aims the
    /// focus at whichever one is about to exist.
    private enum Field: Hashable {
        case secure, plain
    }
    @FocusState private var focusedField: Field?
    private var focused: Bool { focusedField != nil }
    /// Which field the current mode renders — the focus target.
    private var activeField: Field { secure && !revealed ? .secure : .plain }

    /// Recomputed from the current value — clears itself once the text is
    /// clean again, nothing latches.
    private var hasNonASCII: Bool {
        text.contains { !$0.isASCII }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: secure ? "key.fill" : "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(focused ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                Group {
                    if secure && !revealed {
                        SecureField(placeholder, text: $text)
                            .focused($focusedField, equals: .secure)
                    } else {
                        TextField(placeholder, text: $text)
                            .focused($focusedField, equals: .plain)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                // Neither a password nor a username is a word: autocorrect,
                // completion and text replacement have no business rewriting
                // one — and the revealed field is an ordinary TextField, so
                // without this they would.
                .autocorrectionDisabled(true)
                .noAutoFill()
                .onSubmit(onSubmit)
                if secure {
                    Button {
                        // Only follow the focus if the field HAD it (the rule
                        // RevealableSecureField learned): re-hiding must not
                        // engage secure input for a field nobody is typing in.
                        let wasFocused = focused
                        revealed.toggle()
                        guard wasFocused else { return }
                        // Aim at the field that is about to exist; it isn't
                        // installed yet in this runloop pass.
                        let target: Field = revealed ? .plain : .secure
                        DispatchQueue.main.async {
                            focusedField = target
                            moveCaretToEndOfFocusedField()
                        }
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(revealed ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        focused ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.14),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)

            // Same policy as RevealableSecureField: keep the pasted value
            // intact, just flag it — a silently mangled paste is
            // undebuggable. The field takes these characters and SSHWorker
            // sends them as typed; whether the far end accepts them is the
            // far end's business. One line, deliberately: a popup is sized
            // once and a wrapped warning gets clipped. The line is ALWAYS
            // laid out (invisible when there is nothing to say) so the field
            // never jumps up when the warning appears (the user, 2026-10-09).
            Text("Contains non-ASCII characters — sent exactly as typed")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: SheepAlert.cautionYellow))
                .opacity(hasNonASCII ? 1 : 0)
                .accessibilityHidden(!hasNonASCII)
        }
        .onChange(of: focusTrigger) {
            let target = activeField
            DispatchQueue.main.async { focusedField = target }
        }
        .onAppear {
            guard focusOnAppear else { return }
            let target = activeField
            DispatchQueue.main.async { focusedField = target }
        }
        .onChange(of: focused) {
            if focused { AuthPrompt.forceASCIIKeyboard() }
            onFocusChange?(focused)
        }
    }
}

/// Moves the caret to the END of the field that just took focus.
///
/// A field becoming first responder selects all of its text (standard
/// AppKit), so revealing a password and then typing one more character
/// wiped everything the user had entered. There is no SwiftUI API for the
/// selection, so reach for the field editor once the focus has actually
/// landed — two hops: one for SwiftUI to install the new field, one for
/// AppKit to make it first responder.
@MainActor
func moveCaretToEndOfFocusedField() {
    DispatchQueue.main.async {
        guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
}
