import AppKit

// The updater's alerts drawn centred, for any Sheep app (9 Oct 2026, the
// user: every app's update alert is centred like SheepTerm's). GENERIC like
// the rest of this folder: copy it unchanged and pass
// `CenteredUpdatePresenter()` as `UpdateHooks.presenter`. SheepTerm itself
// keeps `SheepAlertUpdatePresenter` (its house SheepAlert, same layout).
//
// Why not NSAlert: on macOS 26 it centres its icon and title only while the
// text is short (about three lines, no accessory view); past that it flips to
// the left-aligned layout and nothing public turns that off. The Details page
// carries the release notes as an accessory, so a plain NSAlert drew it
// against the left edge. Here the layout never depends on the text:
//   • the app icon (64 pt), title, message, accessory and buttons are one
//     centred column, 288 pt wide (`Updater.notesWidth`);
//   • the panel opens centred on the window the user is looking at, or on
//     the screen when the app has none up (a menu-bar app);
//   • the first button is the main action, painted SheepAlert's soft blue,
//     and answers Return unless `returnAnswersFirst` is false; Escape presses
//     Later / Back / Close / OK, whichever is there;
//   • two short buttons sit side by side, more are stacked full width.

@MainActor
struct CenteredUpdatePresenter: UpdateAlertPresenting {
    /// Bring the app forward first: a menu-bar (LSUIElement) app is never
    /// active on its own, so an automatic offer would open behind other windows.
    var activatesApp = false
    /// false: the first button (Install & Relaunch) answers a click only —
    /// for an app whose alert can take the focus while the user is typing
    /// elsewhere (a Return meant for another window must never install).
    var returnAnswersFirst = true

    func present(title: String, message: String, accessory: NSView?, buttons: [UpdateAlertButton]) -> Int {
        if activatesApp { NSApp.activate() }
        let alert = UpdateAlertPanel(title: title, message: message, accessory: accessory,
                                     buttons: buttons.map(\.title), returnAnswersFirst: returnAnswersFirst)
        return alert.runModal()
    }
}

@MainActor
final class UpdateAlertPanel: NSObject {
    static let contentWidth: CGFloat = 288
    /// Titles Escape answers, first match wins.
    static let escapeTitles = ["Later", "Back", "Close", "OK"]

    private let panel: Panel
    private var buttons: [NSButton] = []

    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?
        /// The painted (borderless) default button is not the window's default
        /// button, so the panel answers Return for it.
        weak var returnButton: NSButton?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let returnButton, event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
               event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
                returnButton.performClick(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// SheepAlert's soft default blue, drawn by hand: the system default tint
    /// only shows while the panel is key.
    static let defaultBlue = NSColor(srgbRed: 0.42, green: 0.64, blue: 0.82, alpha: 1)

    init(title: String, message: String, accessory: NSView?, buttons titles: [String], returnAnswersFirst: Bool) {
        let width = Self.contentWidth
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width + 56, height: 200),
                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }

        var rows: [NSView] = []
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        rows.append(icon)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .centerX
        text.spacing = 6
        if !title.isEmpty {
            text.addArrangedSubview(Self.label(title, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor))
        }
        if !message.isEmpty {
            text.addArrangedSubview(Self.label(message, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        rows.append(text)

        if let accessory {
            let size = accessory.frame.size
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.widthAnchor.constraint(equalToConstant: min(max(size.width, 1), width)).isActive = true
            accessory.heightAnchor.constraint(equalToConstant: max(size.height, 1)).isActive = true
            rows.append(accessory)
        }

        for (index, title) in (titles.isEmpty ? ["OK"] : titles).enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .push
            button.controlSize = .large
            button.tag = index
            if index == 0 {
                // The main action is blue either way; Return presses it only when allowed.
                Self.paint(button, Self.defaultBlue)
                if returnAnswersFirst { panel.returnButton = button }
            }
            buttons.append(button)
        }
        let half = (width - 10) / 2
        let pairFits = buttons.count == 2 && buttons.allSatisfy { $0.fittingSize.width + 16 <= half }
        // Apple's order: a side-by-side pair puts the main action (the first
        // button) on the RIGHT, the dismiss on its left; a stack keeps the
        // main action on top.
        let buttonStack = NSStackView(views: pairFits ? Array(buttons.reversed()) : buttons)
        buttonStack.orientation = pairFits ? .horizontal : .vertical
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = pairFits ? 10 : 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.widthAnchor.constraint(equalToConstant: width).isActive = true
        if !pairFits {
            for button in buttons { button.widthAnchor.constraint(equalToConstant: width).isActive = true }
        }
        rows.append(buttonStack)

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.setCustomSpacing(14, after: icon)
        column.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false

        // Rounded glass behind the column.
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 24
        glass.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(glass)
        container.addSubview(column)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: width + 56),
        ])
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width + 56, height: column.fittingSize.height))
        panel.onEscape = { [weak self] in self?.escape() }
    }

    /// The pressed button's index (in the order given).
    func runModal() -> Int {
        Self.center(panel, over: NSApp.keyWindow ?? NSApp.mainWindow)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response.rawValue
    }

    /// Centred on the window the user is looking at; no visible window →
    /// the screen's centre. Kept on that window's screen.
    static func center(_ panel: NSWindow, over window: NSWindow?) {
        guard let window, window !== panel, window.isVisible else { panel.center(); return }
        let host = window.frame
        let size = panel.frame.size
        var origin = NSPoint(x: host.midX - size.width / 2, y: host.midY - size.height / 2)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    @objc private func pressed(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }

    private func escape() {
        for title in Self.escapeTitles {
            if let button = buttons.first(where: { $0.title == title }) { button.performClick(nil); return }
        }
    }

    private static func paint(_ button: NSButton, _ color: NSColor) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 14
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold),
        ])
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = contentWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}
