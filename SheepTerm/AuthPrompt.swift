import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Glassy macOS-style modal used for SSH username/password prompts.
/// Runs a modal session so the SSH worker thread can block on the answer.
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

            HStack(spacing: 9) {
                Image(systemName: secure ? "key.fill" : "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(focused ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                Group {
                    if secure && !revealed {
                        SecureField("Password", text: $text)
                            .focused($focusedField, equals: .secure)
                    } else {
                        TextField(secure ? "Password" : "Username", text: $text)
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
                .onSubmit { completion(answer) }
                if secure {
                    Button {
                        revealed.toggle()
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

            if hasNonASCII {
                // Same policy as RevealableSecureField: keep the pasted value
                // intact, just flag it — a silently mangled paste is
                // undebuggable.
                //
                // What it used to say — "passwords are ASCII only" — was a
                // rule nothing here enforces: the field takes these
                // characters and SSHWorker sends them as typed. Whether the
                // far end accepts them is the far end's business, and this
                // dialog cannot know. All this app does is switch the
                // keyboard to an ASCII-capable layout when the panel opens.
                //
                // One line, deliberately: the panel is sized ONCE from
                // `hosting.fittingSize` before this warning can appear, so a
                // message that wraps to three lines is a message that gets
                // clipped.
                Text("Contains non-ASCII characters — sent exactly as typed")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

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
        .background(
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
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
            let target = activeField
            DispatchQueue.main.async { focusedField = target }
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
