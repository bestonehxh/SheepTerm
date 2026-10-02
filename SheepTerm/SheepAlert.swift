import AppKit
import SwiftUI

/// Every alert in the app (4.1 (38)): a drop-in for `NSAlert` — same
/// properties, same `addButton` order and response codes
/// (`.alertFirstButtonReturn` …), `runModal()` and
/// `beginSheetModal(for:completionHandler:)` — drawn as the centred glass
/// panel the SSH password and host-key prompts use.
///
/// Why not NSAlert: on macOS 26 it centres its icon and title only while the
/// text block is short (about three rendered lines, no accessory view); past
/// that it flips to the left-aligned layout and nothing public turns that
/// off. The app spent releases keeping every message under that limit and
/// still had dialogs (Quit with a session list, the import diff, the host
/// key fingerprint) hugging the left edge. Here the layout never changes
/// with the length of the text.
///
/// Kept from NSAlert on purpose, because call sites rely on it:
///   • the first button is the default (Return) — reassigning
///     `keyEquivalent` on the returned NSButton works as it did;
///   • a button titled "Cancel" that is not first answers Escape, and
///     Escape (cancelOperation) presses "Cancel" wherever it is;
///   • `window` is the panel, so `sheetParent?.endSheet(window, …)` tears a
///     sheet down exactly as before;
///   • the object keeps itself alive while a sheet is up, like NSAlert.
@MainActor
final class SheepAlert: NSObject {
    var messageText = ""
    var informativeText = ""
    /// Accepted for call-site compatibility; every alert reads the same.
    var alertStyle: NSAlert.Style = .warning
    var accessoryView: NSView?
    var icon: NSImage?
    private(set) var buttons: [NSButton] = []

    private var panel: Panel?
    private var sheetCompletion: ((NSApplication.ModalResponse) -> Void)?
    /// Sheets outlive the caller's local `let alert`; NSAlert retains itself
    /// for the duration and so do we.
    private static var presentedSheets: Set<SheepAlert> = []

    static let contentWidth: CGFloat = 288

    @discardableResult
    func addButton(withTitle title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count
        if buttons.isEmpty {
            button.keyEquivalent = "\r"
        } else if title == "Cancel" {
            button.keyEquivalent = "\u{1b}"
        } else if title == "Don't Save" {
            button.keyEquivalent = "d"
            button.keyEquivalentModifierMask = .command
        }
        buttons.append(button)
        return button
    }

    /// The panel (built on first use) — what `runModal` shows and what a
    /// sheet is attached as.
    var window: NSWindow { build() }

    /// NSAlert compatibility: builds the panel so its size is known.
    func layout() { _ = build() }

    @discardableResult
    func sheepStyled() -> SheepAlert { self }

    /// Discardable like NSAlert's (an Objective-C method never warned):
    /// a one-button "OK" alert has nothing to read back.
    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        let panel = build()
        panel.center()
        let response = NSApp.runModal(for: panel)
        // orderOut, NOT close(): close() would post the last-window-closed
        // question, and a prompt can be the only window on screen (see
        // AuthPrompt.ask).
        panel.orderOut(nil)
        return response
    }

    func beginSheetModal(for parent: NSWindow,
                         completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let panel = build()
        sheetCompletion = completionHandler
        Self.presentedSheets.insert(self)
        parent.beginSheet(panel) { [self] response in
            panel.orderOut(nil)
            let completion = sheetCompletion
            sheetCompletion = nil
            Self.presentedSheets.remove(self)
            completion?(response)
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    /// Escape with no Escape button: press "Cancel" if there is one.
    fileprivate func cancel() {
        if let cancel = buttons.first(where: { $0.title == "Cancel" }) {
            cancel.performClick(nil)
        }
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let panel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
    }

    // MARK: - Building

    fileprivate final class Panel: NSPanel {
        weak var owner: SheepAlert?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { owner?.cancel() }
    }

    private func build() -> Panel {
        if let panel { return panel }
        if buttons.isEmpty { addButton(withTitle: "OK") }

        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 56, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.owner = self
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

        let iconView = NSImageView(image: icon ?? NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])
        rows.append(iconView)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .centerX
        text.spacing = 6
        if !messageText.isEmpty {
            text.addArrangedSubview(Self.label(messageText,
                                               font: .systemFont(ofSize: 14, weight: .semibold),
                                               color: .labelColor))
        }
        if !informativeText.isEmpty {
            text.addArrangedSubview(Self.label(informativeText,
                                               font: .systemFont(ofSize: 12),
                                               color: .secondaryLabelColor))
        }
        rows.append(text)

        if let accessoryView {
            // An accessory arrives with its own frame (as NSAlert expects);
            // keep that size, never wider than the text column.
            let size = accessoryView.frame.size
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                accessoryView.widthAnchor.constraint(equalToConstant: min(max(size.width, 1), Self.contentWidth)),
                accessoryView.heightAnchor.constraint(equalToConstant: max(size.height, 1)),
            ])
            rows.append(accessoryView)
        }

        // Two buttons side by side (as NSAlert lays out a short pair), three
        // or more stacked; every button the full width it is given.
        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = buttons.count == 2 ? .horizontal : .vertical
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = buttons.count == 2 ? 10 : 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        if buttonStack.orientation == .vertical {
            for button in buttons {
                button.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            }
        }
        rows.append(buttonStack)

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.setCustomSpacing(14, after: iconView)
        column.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false

        // The glass chrome, drawn by the same SwiftUI shape the password
        // prompt uses, behind the AppKit content.
        let chrome = NSHostingView(rootView: SheepAlertChrome())
        chrome.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(chrome)
        container.addSubview(column)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.contentWidth + 56),
        ])
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.contentWidth + 56, height: column.fittingSize.height))
        self.panel = panel
        return panel
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

/// The rounded glass of `AuthPromptView`, as a background.
private struct SheepAlertChrome: View {
    var body: some View {
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
            // The panel is titled (for key status) with a hidden, full-size
            // titlebar: without this the glass respected the 32 pt titlebar
            // safe area and slid down under the content.
            .ignoresSafeArea()
    }
}
