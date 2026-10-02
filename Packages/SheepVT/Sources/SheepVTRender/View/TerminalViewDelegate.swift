// SheepVTRender — what `TerminalView` needs from its host.
//
// The host owns the connection (SSH worker, serial port, pty): the view hands
// it bytes to write and tells it when the geometry, the title or the viewport
// moved. Everything here is called on the main actor, from inside the view's
// own event handling — a delegate may feed the view back synchronously.
//
// Every method except `send` has a default, so a host that only wants to see
// keystrokes implements one function.

import Foundation

/// The fate of one OSC 52 write (see `TerminalViewDelegate.clipboardWrite`).
public nonisolated enum ClipboardWriteOutcome: Equatable, Sendable {
    /// On the pasteboard. `changeCount` is the pasteboard's count right after
    /// the write, so a host can tell later whether what is on the clipboard
    /// is still what the device put there (any other copy moves it).
    case written(bytes: Int, changeCount: Int)
    /// The host's `allowsClipboardWrite` said no; the pasteboard is untouched.
    case blocked(bytes: Int)
    /// Over `TerminalView.maxClipboardWrite`; the pasteboard is untouched.
    case tooLarge(bytes: Int)
}

public protocol TerminalViewDelegate: AnyObject {
    /// The user typed / pasted / the terminal replied: write these bytes to the
    /// device.
    func send(_ view: TerminalView, bytes: [UInt8])

    /// The grid changed size (only when it actually changed — a font change
    /// that keeps the same cols × rows never reaches here, because every shell
    /// answers a window-size change with a fresh prompt).
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int)

    /// OSC 0/2.
    func titleChanged(_ view: TerminalView, title: String)

    /// OSC 7. `nil` when the shell cleared it.
    func workingDirectoryChanged(_ view: TerminalView, url: String?)

    /// The viewport moved (user scroll, or output while following): overlay
    /// painters repaint from here.
    func scrolled(_ view: TerminalView)

    /// BEL.
    func bell(_ view: TerminalView)

    /// ⌘-click on an OSC 8 hyperlink.
    func openLink(_ view: TerminalView, url: String)

    /// May the device replace the Mac's clipboard (OSC 52)? Asked once per
    /// write, live, so a host can read its setting at that moment. The
    /// default is **no**: the clipboard is shared with every other app, and a
    /// poisoned one carrying a trailing newline runs itself the moment it is
    /// pasted into a terminal. A host that never answers gets no writes.
    func allowsClipboardWrite(_ view: TerminalView) -> Bool

    /// What became of an OSC 52 write — written, refused because the host
    /// said no, or refused for size. Always reported, because nothing else on
    /// screen changes when it happens. Never called for an empty or
    /// non-UTF-8 payload (nothing to write, nothing written).
    func clipboardWrite(_ view: TerminalView, outcome: ClipboardWriteOutcome)

    /// Return false to swallow a paste — the app's SafePaste takes over and
    /// feeds the text back through `send` at its own pace.
    func shouldPaste(_ view: TerminalView, text: String) -> Bool

    /// The user pressed a key that produced `send` bytes — as opposed to a
    /// mouse report, a paste or the terminal's own reply, which also arrive
    /// through `send`. Called just before that `send`.
    func userTyped(_ view: TerminalView)
}

public extension TerminalViewDelegate {
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {}
    func titleChanged(_ view: TerminalView, title: String) {}
    func workingDirectoryChanged(_ view: TerminalView, url: String?) {}
    func scrolled(_ view: TerminalView) {}
    func bell(_ view: TerminalView) {}
    func allowsClipboardWrite(_ view: TerminalView) -> Bool { false }
    func clipboardWrite(_ view: TerminalView, outcome: ClipboardWriteOutcome) {}
    func openLink(_ view: TerminalView, url: String) {}
    func shouldPaste(_ view: TerminalView, text: String) -> Bool { true }
    func userTyped(_ view: TerminalView) {}
}
