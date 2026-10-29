import AppKit
import SwiftUI

/// "Garbled? [Try 115200] ×" — the serial tab's wrong-speed hint (6.0 (12),
/// `ConsoleBaudGuess`). Top right of the terminal, where the status HUD sits;
/// non-modal: nothing is dimmed and the keyboard stays in the terminal. The
/// popups' glass (`popupChrome`) and the card's accent button (`CardButton`).
struct BaudHintContent: View {
    /// "Garbled?" or, when nothing came back at all, "No response?" (6.0 (13)).
    var reason: ConsoleBaudGuess.HintReason = .garbled
    let rate: Int
    let onTry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            (reason == .noResponse ? Text("No response?") : Text("Garbled?"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            CardButton(String(localized: "Try \(String(rate))"), role: .accent,
                       help: String(localized: "Change the port's speed to \(String(rate)) baud — nothing is sent to the device")) { onTry() }
                .frame(width: 112)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(String(localized: "No more speed hints in this tab"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .popupChrome()
    }
}

/// The AppKit side: an NSHostingView that never takes the keyboard.
final class BaudHintView: NSHostingView<BaudHintContent> {
    override var acceptsFirstResponder: Bool { false }
    /// The arrow over the card: it sits on the terminal, whose cursor rect is the I-beam everywhere (the user saw a text cursor on
    /// "Try 115200", 6.0 (12)). Same rule as the connection card.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
