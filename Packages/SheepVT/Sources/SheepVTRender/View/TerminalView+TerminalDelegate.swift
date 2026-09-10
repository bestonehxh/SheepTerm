// SheepVTRender — the view as the terminal's delegate.
//
// `TerminalDelegate` belongs to the core, which knows nothing about actors: it
// calls back on whatever queue fed it. This view always feeds on main (the app
// hops there before every `feed`), so each callback asserts that and forwards.
// `MainActor.assumeIsolated` is the same bridge `SSHTerminalController` already
// uses in the app — it is a claim about the calling queue, not a hop.

import AppKit

extension TerminalView: TerminalDelegate {

    public nonisolated func send(_ terminal: Terminal, bytes: [UInt8]) {
        MainActor.assumeIsolated { self.send(bytes, keystroke: false) }
    }

    public nonisolated func titleChanged(_ terminal: Terminal, title: String) {
        MainActor.assumeIsolated { self.delegate?.titleChanged(self, title: title) }
    }

    public nonisolated func bell(_ terminal: Terminal) {
        MainActor.assumeIsolated { self.delegate?.bell(self) }
    }

    public nonisolated func workingDirectoryChanged(_ terminal: Terminal, url: String) {
        MainActor.assumeIsolated {
            self.delegate?.workingDirectoryChanged(self, url: url.isEmpty ? nil : url)
        }
    }

    /// OSC 52 write. The read side (`getClipboard`) stays refused below — a
    /// program that can read the pasteboard can read the user's passwords.
    ///
    /// The write side is kept, because copying out of vim or tmux on the far
    /// end is what it is for, but not silently and not without a limit. A
    /// device that has been compromised can otherwise replace the clipboard as
    /// often as it likes with as much as it likes, and a payload ending in a
    /// newline runs itself the moment it is pasted into another terminal. The
    /// view tells its delegate every time, and the delegate is what puts a line
    /// in the session; `maxClipboardWrite` is the ceiling on one write (the
    /// parser's own 8 MiB payload cap is far above anything a copy needs).
    public static let maxClipboardWrite = 512 * 1024

    public nonisolated func setClipboard(_ terminal: Terminal, selection: String, data: [UInt8]) {
        MainActor.assumeIsolated {
            guard let text = String(bytes: data, encoding: .utf8), !text.isEmpty else { return }
            guard data.count <= TerminalView.maxClipboardWrite else {
                self.delegate?.clipboardWritten(self, bytes: -data.count)   // negative = refused
                return
            }
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            self.delegate?.clipboardWritten(self, bytes: data.count)
        }
    }

    public nonisolated func getClipboard(_ terminal: Terminal, selection: String) -> [UInt8]? {
        nil
    }

    public nonisolated func bufferActivated(_ terminal: Terminal, alternate: Bool) {
        MainActor.assumeIsolated {
            // Line numbers mean nothing across a buffer switch.
            self.selection.clear()
            self.search.invalidate()
            self.currentMatchCleared()
            self.highlight?.invalidate()
            self.renderer?.invalidateRows()
            self.setNeedsFrame()
        }
    }

    public nonisolated func scrolled(_ terminal: Terminal, lines: Int) {
        MainActor.assumeIsolated {
            self.delegate?.scrolled(self)
            self.setNeedsFrame()
        }
    }

    public nonisolated func cursorStyleChanged(_ terminal: Terminal, style: CursorStyle) {
        MainActor.assumeIsolated { self.setNeedsFrame() }
    }

    public nonisolated func pixelSize(_ terminal: Terminal) -> (width: Int, height: Int)? {
        MainActor.assumeIsolated {
            let size = self.metalLayer?.drawableSize ?? self.surfacePixelSize
            guard size.width > 0, size.height > 0 else { return nil }
            return (width: Int(size.width), height: Int(size.height))
        }
    }

    /// Mode 2026: the program is drawing a frame of its own — hold ours until
    /// it says it is done, but never longer than `synchronizedOutputHold`.
    public nonisolated func synchronizedOutputChanged(_ terminal: Terminal, enabled: Bool) {
        MainActor.assumeIsolated {
            self.holdFrames(enabled)
        }
    }
}
