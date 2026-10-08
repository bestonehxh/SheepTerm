// SheepVTRender — the focus callback (4.2 (7), split panes).
//
// With several terminal views in one window the host has to know which one
// the keyboard went to; `becomeFirstResponder` / `resignFirstResponder` tell
// the delegate.

import AppKit
import Testing

@testable import SheepVTRender
import SheepVT

@Suite struct FocusDelegateTests {
    final class Recorder: TerminalViewDelegate {
        var events: [Bool] = []
        func send(_ view: TerminalView, bytes: [UInt8]) {}
        func focusChanged(_ view: TerminalView, focused: Bool) { events.append(focused) }
    }

    @Test func firstResponderChangesReachTheDelegate() {
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), cols: 20, rows: 5)
        let recorder = Recorder()
        view.delegate = recorder
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        #expect(recorder.events == [true])
        #expect(window.makeFirstResponder(nil))
        #expect(recorder.events == [true, false])
        view.removeFromSuperview()
    }
}
