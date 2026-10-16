import AppKit
import SwiftUI

/// The question Confirm Dangerous Commands puts over the tab (5.0 (22)):
/// the connection card's parts (`popupChrome`, `SheepLockBadge`, the
/// fingerprint's boxed block, `TrustButtonStyle` capsules) at a smaller
/// size — the host's name, the command, Cancel and Send.
///
/// Cancel is what Return and Escape do; Send takes a click. No
/// `.keyboardShortcut` (another pane's Return would answer it — the
/// connection card's rule). Like that card, this view is the responder
/// chain's stop: no key typed here reaches the terminal behind it.
final class CommandGuardCardView: NSView {
    private let hosting: NSHostingView<CommandGuardCardContent>
    /// true = Send. Called at most once.
    var onAnswer: ((Bool) -> Void)?

    init(title: String, command: String) {
        hosting = NSHostingView(rootView: CommandGuardCardContent(title: title, command: command,
                                                                  answer: { _ in }, tap: {}))
        super.init(frame: .zero)
        hosting.rootView = CommandGuardCardContent(
            title: title, command: command,
            answer: { [weak self] send in self?.answer(send) },
            tap: { [weak self] in self?.takeKeyboard() })
        translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's size; the host falls back to a sheet in a pane smaller
    /// than this plus a margin.
    var fittingCardSize: NSSize { hosting.fittingSize }

    func answer(_ send: Bool) {
        guard let onAnswer else { return }
        self.onAnswer = nil
        onAnswer(send)
    }

    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        if window.firstResponder === self { return true }
        return window.makeFirstResponder(self)
    }

    var hasKeyboard: Bool { window?.firstResponder === self }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 53: answer(false)   // Return, Enter, Escape = Cancel
        default: NSSound.beep()
        }
    }

    override func cancelOperation(_ sender: Any?) { answer(false) }
    override func doCommand(by selector: Selector) {}
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        responds(to: action) ? super.tryToPerform(action, with: object) : false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

struct CommandGuardCardContent: View {
    let title: String
    let command: String
    let answer: (Bool) -> Void
    let tap: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            SheepLockBadge(symbol: "exclamationmark.triangle.fill", danger: true)
                .frame(width: 64, height: 64)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(command)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: SheepAlert.destructiveRed))
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.14), lineWidth: 1))
            HStack(spacing: 8) {
                Button { answer(false) } label: { Text("Cancel").frame(minWidth: 96).padding(.horizontal, 10) }
                    .buttonStyle(TrustButtonStyle(fill: Color.primary.opacity(0.12), foreground: .primary))
                    .focusable(false)
                    .help("Don't send — the command stays typed (Return / Esc)")
                Button { answer(true) } label: { Text("Send").frame(minWidth: 96).padding(.horizontal, 10) }
                    .buttonStyle(TrustButtonStyle(fill: Color(nsColor: SheepAlert.destructiveRed), foreground: .white))
                    .focusable(false)
                    .help("Send it to the device")
            }
            .frame(height: 30)
        }
        .padding(28)
        .frame(width: 400)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .popupChrome()
    }
}
