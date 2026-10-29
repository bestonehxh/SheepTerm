import AppKit
import SwiftUI

/// The question Danger Command Guard puts over the tab (5.0 (22)):
/// since 6.0 (11) the connection card's own layout and size (card J,
/// `CommandGuardCardContent`) — the host's name, the command, Cancel and Send.
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

/// Card J (6.0 (11)): the connection card's four slots at the same heights
/// and the same size — a red capsule ("Dangerous command") where the stage
/// track is, the session's name over "Can restart or erase the device", the
/// command in a red-edged box on the field's line (its reserved red line
/// under it), Cancel and a red Send. No icon; the old card's red.
struct CommandGuardCardContent: View {
    let title: String
    let command: String
    let answer: (Bool) -> Void
    let tap: () -> Void

    /// How many 13 pt semibold monospaced characters the command's line
    /// holds: the column (card 480 − 2 × 28) less the box's padding, the
    /// glyph and its gap.
    static let lineChars: Int = {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let room = ConnectionCardView.cardWidth - 2 * 28 - 2 * 12 - 13 - 8
        return max(10, Int(room / advance))
    }()

    var body: some View {
        VStack(spacing: ConnectionCardContent.slotGap) {
            StageTrack(nodes: [StageTrack.Node(label: String(localized: "Dangerous command"), symbol: "exclamationmark.triangle.fill")],
                       current: 0, failed: true)
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("Can restart or erase the device")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: ConnectionCardContent.titlesHeight, alignment: .top)
            CardPage(content: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    // One line that always shows the part that made it
                    // dangerous (`CommandGuard.shown`, review 6.0 (11)).
                    Text(CommandGuard.shown(command, maxChars: Self.lineChars))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: SheepAlert.destructiveRed))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: CardBand.size.field)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: SheepAlert.destructiveRed).opacity(0.7), lineWidth: 1))
                // A long command is cut; the whole of it here.
                .help(command)
            }, buttons: {
                CardButton(String(localized: "Cancel"), role: .neutral,
                           help: String(localized: "Don't send — the command stays typed (Return / Esc)")) { answer(false) }
                CardButton(String(localized: "Send"), role: .danger,
                           help: String(localized: "Send it to the device")) { answer(true) }
            })
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(width: ConnectionCardView.cardWidth)
        // The connection card's height (`popupChrome` adds 10 pt each side).
        .frame(height: ConnectionCardView.cardSize.height - 20, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .popupChrome()
    }
}
