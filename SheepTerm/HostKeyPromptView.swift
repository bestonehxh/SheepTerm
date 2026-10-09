import AppKit
import SwiftUI

/// First connection to a host: the same glass panel as the SSH password
/// prompt (`AuthPromptView`), everything centred. It replaced an NSAlert in
/// 4.1 (38): macOS 26 only centres an alert's icon and title while the text
/// is short, and a fingerprint (or any accessory view) flips it to the
/// left-aligned layout — the icon, the title and the host ended up hugging
/// the left edge, and the fingerprint wrapped with a hyphen that is not in
/// the key.
struct HostKeyPromptView: View {
    let target: String
    /// "RSA", "ED25519", "ECDSA P-256", … — see `keyTypeLabel`.
    let keyType: String
    /// The base64 part of "SHA256:…", no prefix.
    let fingerprint: String
    let completion: (Bool) -> Void

    /// SSH key type names as a person reads them.
    static func keyTypeLabel(_ sshName: String) -> String {
        switch sshName {
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": return "RSA"
        case "ssh-ed25519": return "ED25519"
        case "ecdsa-sha2-nistp256": return "ECDSA P-256"
        case "ecdsa-sha2-nistp384": return "ECDSA P-384"
        case "ecdsa-sha2-nistp521": return "ECDSA P-521"
        case "ssh-dss": return "DSA"
        default: return sshName
        }
    }

    /// The fingerprint in two lines of (nearly) equal length, so it never
    /// wraps mid-way at whatever width the text happens to get.
    static func fingerprintLines(_ base64: String) -> (String, String) {
        let first = (base64.count + 1) / 2
        return (String(base64.prefix(first)), String(base64.dropFirst(first)))
    }

    var body: some View {
        VStack(spacing: 18) {
            // The app icon, as the alert this replaced showed it.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(spacing: 4) {
                Text("First connection to")
                    .font(.system(size: 15, weight: .semibold))
                Text(target)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Not in known_hosts yet — compare the fingerprint before you trust it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            FingerprintBlock(keyType: keyType, fingerprint: fingerprint)

            VStack(spacing: 8) {
                // Trust is the green button (the user's choice in 4.1 (38)),
                // but Return still answers CANCEL — trusting a key has to be a
                // deliberate click, never a reflexive Return. Escape cancels
                // too (both in AuthPrompt.confirmHostKey's key monitor).
                Button { completion(true) } label: {
                    Text("Trust & Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(TrustButtonStyle())
                Button { completion(false) } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                // Not `.keyboardShortcut(.defaultAction)`: that paints Cancel
                // blue, and the user wants only Trust coloured (4.2 (2)).
                // Return still answers Cancel — AuthPrompt.confirmHostKey's
                // key monitor maps Return and Escape both to it.
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 350)
        .popupChrome()
        .onExitCommand { completion(false) }
    }
}

/// The key type and the fingerprint in two even lines in a rounded box —
/// the popup's block, shared with the in-tab connection card.
struct FingerprintBlock: View {
    /// "RSA", "ED25519", … (`HostKeyPromptView.keyTypeLabel`).
    let keyType: String
    /// The base64 part of "SHA256:…", no prefix.
    let fingerprint: String
    /// One line (the wide in-tab card, 2026-10-09) instead of the popup's two.
    var oneLine = false

    var body: some View {
        let lines = HostKeyPromptView.fingerprintLines(fingerprint)
        VStack(spacing: 6) {
            Text("\(keyType) key · SHA256")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                if oneLine {
                    Text(fingerprint).lineLimit(1).minimumScaleFactor(0.85)
                } else {
                    Text(lines.0)
                    Text(lines.1)
                }
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
        }
    }
}

/// Solid green, whatever the window's key state — `.borderedProminent`
/// drops its tint to grey in an inactive window, and this button's colour is
/// the point.
struct TrustButtonStyle: ButtonStyle {
    /// Green by default; the in-tab card's row puts its Cancel / Connect
    /// Once beside it in the same capsule, neutral, so the three are one row
    /// of one height.
    var fill = Color(nsColor: SheepAlert.confirmGreen)
    var foreground = Color.white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(Capsule())
    }
}
