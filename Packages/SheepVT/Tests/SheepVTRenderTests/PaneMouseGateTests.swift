// SheepVTRender — split panes: a pane without the keyboard never lets the
// pointer reach its program (TerminalView.pointerNeedsFocus).

import AppKit
import Testing
@testable import SheepVTRender
import SheepVT

@MainActor
private final class Recorder: TerminalViewDelegate {
    var sent: [[UInt8]] = []
    var focus: [Bool] = []
    var scrolls = 0
    var sentBytes: [UInt8] { sent.flatMap { $0 } }
    func send(_ view: TerminalView, bytes: [UInt8]) { sent.append(bytes) }
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) {}
    func titleChanged(_ view: TerminalView, title: String) {}
    func scrolled(_ view: TerminalView) { scrolls += 1 }
    func focusChanged(_ view: TerminalView, focused: Bool) { focus.append(focused) }
}

/// A view in a window, with a plain sibling that can hold the keyboard.
@MainActor
private struct Rig {
    let window: NSWindow
    let view: TerminalView
    let other: NSView
    let delegate = Recorder()

    init(gated: Bool, focused: Bool) {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 520),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        other = FocusableView(frame: CGRect(x: 0, y: 480, width: 800, height: 40))
        root.addSubview(view)
        root.addSubview(other)
        window.contentView = root
        view.delegate = delegate
        view.pointerNeedsFocus = gated
        _ = window.makeFirstResponder(focused ? view : other)
        delegate.focus.removeAll()
    }

    var point: CGPoint { CGPoint(x: view.cellWidth * 3.5, y: view.cellHeight * 2.5) }

    func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func wheel(_ lines: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: lines, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    /// Every button's press / drag / release, plus a bare move.
    func gesture() {
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseDragged(with: mouse(.leftMouseDragged))
        view.mouseUp(with: mouse(.leftMouseUp))
        view.rightMouseDown(with: mouse(.rightMouseDown))
        view.rightMouseDragged(with: mouse(.rightMouseDragged))
        view.rightMouseUp(with: mouse(.rightMouseUp))
        view.otherMouseDown(with: mouse(.otherMouseDown))
        view.otherMouseDragged(with: mouse(.otherMouseDragged))
        view.otherMouseUp(with: mouse(.otherMouseUp))
        view.mouseMoved(with: mouse(.mouseMoved))
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// DECSET: 9 X10, 1000 normal, 1002 button-event, 1003 any-event.
private let trackingModes = ["9", "1000", "1002", "1003"]

@MainActor
@Suite struct PaneMouseGateTests {

    @Test func unfocusedPaneSendsNothingInAnyTrackingMode() {
        for mode in trackingModes {
            let rig = Rig(gated: true, focused: false)
            rig.view.feed("\u{1b}[?\(mode)h\u{1b}[?1006h")
            // The first press only focuses; nothing else of that gesture
            // (drag, release) is reported either.
            rig.view.mouseDown(with: rig.mouse(.leftMouseDown))
            rig.view.mouseDragged(with: rig.mouse(.leftMouseDragged))
            rig.view.mouseUp(with: rig.mouse(.leftMouseUp))
            #expect(rig.delegate.sent.isEmpty, "mode \(mode): click leaked \(rig.delegate.sentBytes)")
            #expect(rig.window.firstResponder === rig.view, "mode \(mode): the click must focus the pane")
        }
    }

    @Test func everyButtonAndMotionIsSilentWhileUnfocused() {
        for mode in trackingModes {
            for button in 0..<3 {
                let rig = Rig(gated: true, focused: false)
                rig.view.feed("\u{1b}[?\(mode)h\u{1b}[?1006h")
                let types: [[NSEvent.EventType]] = [
                    [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                    [.rightMouseDown, .rightMouseDragged, .rightMouseUp],
                    [.otherMouseDown, .otherMouseDragged, .otherMouseUp],
                ]
                let t = types[button]
                switch button {
                case 0:
                    rig.view.mouseDown(with: rig.mouse(t[0])); rig.view.mouseDragged(with: rig.mouse(t[1])); rig.view.mouseUp(with: rig.mouse(t[2]))
                case 1:
                    rig.view.rightMouseDown(with: rig.mouse(t[0])); rig.view.rightMouseDragged(with: rig.mouse(t[1])); rig.view.rightMouseUp(with: rig.mouse(t[2]))
                default:
                    rig.view.otherMouseDown(with: rig.mouse(t[0])); rig.view.otherMouseDragged(with: rig.mouse(t[1])); rig.view.otherMouseUp(with: rig.mouse(t[2]))
                }
                #expect(rig.delegate.sent.isEmpty, "mode \(mode) button \(button) leaked \(rig.delegate.sentBytes)")
            }
            // Pointer motion without a button (any-event tracking).
            let rig = Rig(gated: true, focused: false)
            rig.view.feed("\u{1b}[?\(mode)h\u{1b}[?1006h")
            rig.view.mouseMoved(with: rig.mouse(.mouseMoved))
            #expect(rig.delegate.sent.isEmpty, "mode \(mode): motion leaked")
        }
    }

    @Test func afterTheFocusingClickTheSameGestureIsReported() {
        let rig = Rig(gated: true, focused: false)
        rig.view.feed("\u{1b}[?1000h\u{1b}[?1006h")
        rig.view.mouseDown(with: rig.mouse(.leftMouseDown))
        rig.view.mouseUp(with: rig.mouse(.leftMouseUp))
        #expect(rig.delegate.sent.isEmpty)
        rig.view.mouseDown(with: rig.mouse(.leftMouseDown))
        rig.view.mouseUp(with: rig.mouse(.leftMouseUp))
        #expect(String(decoding: rig.delegate.sentBytes, as: UTF8.self) == "\u{1b}[<0;4;3M\u{1b}[<0;4;3m")
    }

    @Test func focusedAndLonePanesReportExactlyAsBefore() {
        for (gated, focused) in [(true, true), (false, true), (false, false)] {
            let rig = Rig(gated: gated, focused: focused)
            rig.view.feed("\u{1b}[?1000h\u{1b}[?1006h")
            rig.view.mouseDown(with: rig.mouse(.leftMouseDown))
            rig.view.mouseUp(with: rig.mouse(.leftMouseUp))
            #expect(String(decoding: rig.delegate.sentBytes, as: UTF8.self) == "\u{1b}[<0;4;3M\u{1b}[<0;4;3m",
                    "gated=\(gated) focused=\(focused)")
        }
        // Button-event mode: the drag reports motion for a focused pane.
        let rig = Rig(gated: true, focused: true)
        rig.view.feed("\u{1b}[?1002h\u{1b}[?1006h")
        rig.view.mouseDragged(with: rig.mouse(.leftMouseDragged))
        #expect(String(decoding: rig.delegate.sentBytes, as: UTF8.self).hasPrefix("\u{1b}[<32;"))
    }

    @Test func wheelOverAnUnfocusedPaneOnlyScrollsOurScrollback() {
        for mode in trackingModes + ["none"] {
            for alternate in [false, true] {
                let rig = Rig(gated: true, focused: false)
                // Scrollback to move through (main screen), then the mode under test.
                rig.view.feed(String(repeating: "line\r\n", count: 200))
                if alternate { rig.view.feed("\u{1b}[?1049h") }
                rig.view.feed("\u{1b}[?1007h")                       // alternate scroll on
                if mode != "none" { rig.view.feed("\u{1b}[?\(mode)h\u{1b}[?1006h") }
                rig.view.scrollWheel(with: rig.wheel(3))
                rig.view.scrollWheel(with: rig.wheel(-3))
                #expect(rig.delegate.sent.isEmpty,
                        "mode \(mode) alt=\(alternate): wheel leaked \(rig.delegate.sentBytes)")
                #expect(rig.window.firstResponder === rig.other, "a wheel must not focus the pane")
            }
        }
        // And it really did scroll our own scrollback.
        let rig = Rig(gated: true, focused: false)
        rig.view.feed(String(repeating: "line\r\n", count: 200))
        rig.view.feed("\u{1b}[?1000h")
        let before = rig.view.terminal.buffer.ydisp
        rig.view.scrollWheel(with: rig.wheel(3))
        #expect(rig.view.terminal.buffer.ydisp < before)
        #expect(rig.delegate.sent.isEmpty)
    }

    @Test func wheelOverTheFocusedOrLonePaneIsUnchanged() {
        for (gated, focused) in [(true, true), (false, true), (false, false)] {
            // Mouse tracking: wheel notches become reports.
            let tracked = Rig(gated: gated, focused: focused)
            tracked.view.feed("\u{1b}[?1000h\u{1b}[?1006h")
            tracked.view.scrollWheel(with: tracked.wheel(1))
            #expect(String(decoding: tracked.delegate.sentBytes, as: UTF8.self).hasPrefix("\u{1b}[<64;"),
                    "gated=\(gated) focused=\(focused): wheel report")
            // Alternate scroll: cursor keys.
            let alt = Rig(gated: gated, focused: focused)
            alt.view.feed("\u{1b}[?1049h\u{1b}[?1007h")
            alt.view.scrollWheel(with: alt.wheel(1))
            #expect(String(decoding: alt.delegate.sentBytes, as: UTF8.self) == "\u{1b}[A",
                    "gated=\(gated) focused=\(focused): alternate scroll")
        }
    }
}
