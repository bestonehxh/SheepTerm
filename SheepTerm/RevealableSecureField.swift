import AppKit
import Combine
import SwiftUI

extension View {
    /// Keep macOS AutoFill (Passwords, contacts, one-time codes) out of the
    /// app's own fields. Credentials live only in SheepTerm's Keychain, and the
    /// system's suggestion bar has no business offering a website login for a
    /// device password. AppKit has no "off" switch: the heuristic keys on the
    /// field's `contentType` (a secure field is a `.password` unless told
    /// otherwise), so we set one that no AutoFill provider recognises. It goes
    /// in the environment, so one call at a sheet's root covers every field
    /// under it. Typing, paste and the reveal toggle are untouched.
    func noAutoFill() -> some View {
        textContentType(NSTextContentType(rawValue: "sheepterm.none"))
    }
}

/// Password field with an eye button to reveal/hide what's typed.
struct RevealableSecureField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false
    /// Same reason as AuthPromptView: SecureField and TextField are two
    /// different views, so one shared focus binding is lost the moment the
    /// eye button swaps them. Each claims its own value.
    private enum Field: Hashable {
        case secure, plain
    }
    @FocusState private var focusedField: Field?
    /// A field keeps its focus while its window is in the background; only
    /// the KEY window's field may hold the keyboard to English, or Thai
    /// would be unusable everywhere else in the app (the terminal included).
    @Environment(\.controlActiveState) private var activeState
    /// `.inactive` = the window is in the background; a popover's content
    /// reports `.active`/`.key` while it is the one being typed into.
    private var holdsKeyboard: Bool { focusedField != nil && activeState != .inactive }

    /// Recomputed from the current value, so the warning clears itself as
    /// soon as the text is clean again — nothing latches.
    private var hasNonASCII: Bool {
        text.contains { !$0.isASCII }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField(title, text: $text)
                            .focused($focusedField, equals: .plain)
                    } else {
                        SecureField(title, text: $text)
                            .focused($focusedField, equals: .secure)
                    }
                }
                // A password is not a word: autocorrect, completion and text
                // replacement must not rewrite one. The revealed form is an
                // ordinary TextField, so without this they would (smart
                // quotes alone would silently change what gets sent).
                .autocorrectionDisabled(true)
                .noAutoFill()
                .onChange(of: focusedField) {
                    if focusedField != nil {
                        AuthPrompt.forceASCIIKeyboard()
                    }
                }
                // ALWAYS English while the caret is here, not just on arrival:
                // switching to Thai mid-password (⌃Space, the revealed form is
                // a plain TextField with no secure-input lock) is switched
                // straight back. Leaving the field leaves the keyboard alone.
                .onReceive(DistributedNotificationCenter.default().publisher(for: AuthPrompt.inputSourceChanged)) { _ in
                    if holdsKeyboard { AuthPrompt.keepASCIIKeyboard() }
                }
                .onChange(of: text) {
                    if holdsKeyboard { AuthPrompt.keepASCIIKeyboard() }
                }
                Button {
                    // Only follow the focus if the field HAD it. Clicking the
                    // eye to check what you typed while the caret sits in
                    // another field used to yank focus over here — and, when
                    // it re-hid the value, engage secure input (which locks
                    // input-source switching app-wide) for a field nobody
                    // was typing into.
                    let wasFocused = focusedField != nil
                    revealed.toggle()
                    guard wasFocused else { return }
                    let target: Field = revealed ? .plain : .secure
                    DispatchQueue.main.async {
                        focusedField = target
                        moveCaretToEndOfFocusedField()
                    }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide password" : "Show password")
            }
            if hasNonASCII {
                // The value is kept as pasted — only warned about, never
                // silently mangled.
                // Not "passwords are ASCII only" — that was never this app's
                // rule to make. The field keeps what was pasted and sends it
                // byte for byte; whether the far end accepts it is the far
                // end's business. AuthPrompt says the same thing in the same
                // words, and used to cite this line as its authority.
                Text("Contains non-ASCII characters — sent exactly as typed")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: SheepAlert.cautionYellow))
            }
        }
    }
}

/// The auth dialog badge: SheepTerm's sheep face guarded by a little lock.
struct SheepLockBadge: View {
    /// The badge's symbol: the lock the password popup always had; the card
    /// passes the stage's (person / key / lock / warning), nil = no badge.
    var symbol: String? = "lock.fill"
    /// Red symbol for a host key that no longer matches.
    var danger = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
                .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)

            // mini sheep face (same DNA as the app icon)
            ZStack {
                Circle()
                    .fill(Color(red: 0.96, green: 0.95, blue: 0.92))
                    .frame(width: 42, height: 42)
                Ellipse()
                    .fill(Color(red: 0.97, green: 0.91, blue: 0.83))
                    .frame(width: 30, height: 26)
                    .offset(y: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.13))
                    .offset(x: -5, y: 0)
                Capsule()
                    .fill(Color(red: 0.16, green: 0.15, blue: 0.13))
                    .frame(width: 9, height: 2.5)
                    .offset(x: 1, y: 8)
            }

            // stage badge (the lock, on the password popup)
            if let symbol {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.11, green: 0.12, blue: 0.16))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(danger ? Color(nsColor: SheepAlert.destructiveRed) : Color(red: 0.99, green: 0.85, blue: 0.45))
                }
                .offset(x: 21, y: 21)
            }
        }
    }
}
