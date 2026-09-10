// SheepVT — what the terminal needs from its host. Every method has a
// default so a headless terminal (tests, log replay) needs no delegate.
// Called on the thread that feeds the terminal.

public enum CursorStyle: Int, Sendable { case blinkBlock = 1, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar }

public enum MouseTracking: Sendable { case none, x10, normal, buttonEvent, anyEvent }
public enum MouseEncoding: Sendable { case x10, utf8, sgr, urxvt, sgrPixels }

public protocol TerminalDelegate: AnyObject {
    /// Bytes the terminal wants written back to the device (DA/DSR/DECRQM
    /// replies, OSC colour queries, kitty keyboard queries, …).
    func send(_ terminal: Terminal, bytes: [UInt8])
    /// OSC 0/2 (window title) and OSC 1 (icon name).
    func titleChanged(_ terminal: Terminal, title: String)
    func iconNameChanged(_ terminal: Terminal, name: String)
    /// BEL.
    func bell(_ terminal: Terminal)
    /// OSC 52: the program wants to set the clipboard (already base64-decoded).
    /// `selection` is the OSC 52 selector string ("c", "p", "s", …).
    func setClipboard(_ terminal: Terminal, selection: String, data: [UInt8])
    /// OSC 52 query. Return the clipboard bytes to reply with, or nil to refuse.
    func getClipboard(_ terminal: Terminal, selection: String) -> [UInt8]?
    /// OSC 7: current working directory URL as sent by the shell.
    func workingDirectoryChanged(_ terminal: Terminal, url: String)
    /// Primary ↔ alternate screen switched.
    func bufferActivated(_ terminal: Terminal, alternate: Bool)
    /// The visible area scrolled by `lines` (positive = content moved up) —
    /// a hint so a renderer can blit instead of repaint.
    func scrolled(_ terminal: Terminal, lines: Int)
    /// DECSCUSR.
    func cursorStyleChanged(_ terminal: Terminal, style: CursorStyle)
    /// XTWINOPS 14 asks for the text area size in pixels; return nil if unknown.
    func pixelSize(_ terminal: Terminal) -> (width: Int, height: Int)?
    /// XTWINOPS 8 (resize request from the program). Hosts usually ignore it.
    func resizeRequested(_ terminal: Terminal, cols: Int, rows: Int)
    /// OSC 9 / OSC 777 notification.
    func notification(_ terminal: Terminal, title: String, body: String)
    /// OSC 133 A/B/C/D shell-integration marks, with the screen row they landed on.
    func semanticPrompt(_ terminal: Terminal, mark: Character, row: Int)
    /// Mode 2026 synchronized-output toggled; a renderer should hold paints while true.
    func synchronizedOutputChanged(_ terminal: Terminal, enabled: Bool)
    /// A sequence the terminal does not implement (for diagnostics/telemetry).
    func unhandled(_ terminal: Terminal, description: String)
}

public extension TerminalDelegate {
    func send(_ terminal: Terminal, bytes: [UInt8]) {}
    func titleChanged(_ terminal: Terminal, title: String) {}
    func iconNameChanged(_ terminal: Terminal, name: String) {}
    func bell(_ terminal: Terminal) {}
    func setClipboard(_ terminal: Terminal, selection: String, data: [UInt8]) {}
    func getClipboard(_ terminal: Terminal, selection: String) -> [UInt8]? { nil }
    func workingDirectoryChanged(_ terminal: Terminal, url: String) {}
    func bufferActivated(_ terminal: Terminal, alternate: Bool) {}
    func scrolled(_ terminal: Terminal, lines: Int) {}
    func cursorStyleChanged(_ terminal: Terminal, style: CursorStyle) {}
    func pixelSize(_ terminal: Terminal) -> (width: Int, height: Int)? { nil }
    func resizeRequested(_ terminal: Terminal, cols: Int, rows: Int) {}
    func notification(_ terminal: Terminal, title: String, body: String) {}
    func semanticPrompt(_ terminal: Terminal, mark: Character, row: Int) {}
    func synchronizedOutputChanged(_ terminal: Terminal, enabled: Bool) {}
    func unhandled(_ terminal: Terminal, description: String) {}
}
