// SheepVTRender — pointer handling.
//
// Two worlds share the mouse. When the program asked for mouse reporting
// (DECSET 9/1000/1002/1003) every press, drag and wheel notch becomes bytes;
// holding ⇧ bypasses that so the user can always select text out of vim. When
// it did not, the same gestures drive `Selection` — in scroll-invariant
// positions, so output arriving under the pointer never moves what is selected.

import AppKit

extension TerminalView {

    // MARK: - Buttons

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .left, action: .press, at: point) { return }

        let hit = hitTest(point: point)
        dragAnchor = hit
        dragStartPoint = point
        dragging = false
        switch event.clickCount {
        case 1:
            if event.modifierFlags.contains(.shift), selection.isActive {
                selection.extend(to: hit)
                dragging = true
                dragMode = selection.mode
            } else {
                // A plain click clears; the selection only begins once the
                // pointer actually moves (a click is not a zero-width
                // selection).
                selection.clear()
                dragMode = event.modifierFlags.contains(.option) ? .block : .character
            }
        case 2:
            dragMode = .word
            selection.begin(at: hit, mode: .word)
            dragging = true
        default:
            dragMode = .line
            selection.begin(at: hit, mode: .line)
            dragging = true
        }
        setNeedsFrame()
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .left, action: .motion, at: point) { return }

        lastDragPoint = point
        if !dragging, let anchor = dragAnchor {
            // A click that wobbles a pixel is still a click: only a drag that
            // reaches another cell (or moves a few points) starts selecting.
            let moved = hitTest(point: point) != anchor
                || abs(point.x - (dragStartPoint?.x ?? point.x)) > 3
                || abs(point.y - (dragStartPoint?.y ?? point.y)) > 3
            guard moved else { return }
            selection.begin(at: anchor, mode: dragMode)
            dragging = true
        }
        guard dragging else { return }
        selection.extend(to: hitTest(point: point))

        // Held past an edge the pointer stops sending events, so a timer keeps
        // the viewport moving.
        let row = gridRow(at: point)
        if row < 0 {
            autoScrollDelta = -scrollingVelocity(-row)
        } else if row >= terminal.rows {
            autoScrollDelta = scrollingVelocity(row - terminal.rows + 1)
        } else {
            autoScrollDelta = 0
        }
        if autoScrollDelta != 0 { startAutoScroll() } else { stopAutoScroll() }
        setNeedsFrame()
    }

    public override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .left, action: .release, at: point) { return }

        if event.modifierFlags.contains(.command), !dragging,
           let url = link(at: hitTest(point: point)) {
            delegate?.openLink(self, url: url)
        }
        dragging = false
        dragAnchor = nil
        lastDragPoint = nil
    }

    public override func mouseMoved(with event: NSEvent) {
        guard terminal.modes.mouseTracking == .anyEvent else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        reportMouse(event: event, button: .none, action: .motion, at: point)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .right, action: .press, at: point) { return }
        super.rightMouseDown(with: event)
    }

    /// AppKit routes a drag to one method per button, so a right-button drag
    /// never reaches `mouseDragged`. Without this, DECSET 1002 reported the
    /// press and the release of a right-drag but none of the motion in between
    /// — xterm reports it, and so does the middle button below. Selection is a
    /// left-button gesture only, so all this does is report.
    public override func rightMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .right, action: .motion, at: point) { return }
        super.rightMouseDragged(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if reportMouse(event: event, button: .right, action: .release, at: point) { return }
        super.rightMouseUp(with: event)
    }

    /// Middle button: reported when the program asked, otherwise ignored —
    /// middle-click paste is deliberately off (it pastes the wrong thing far
    /// too easily on a device that is about to run what it receives).
    public override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        _ = reportMouse(event: event, button: .middle, action: .press, at: point)
    }

    /// Same story as `rightMouseDragged`: `otherMouseDragged` is the only place
    /// a middle-button drag is delivered.
    public override func otherMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        _ = reportMouse(event: event, button: .middle, action: .motion, at: point)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        _ = reportMouse(event: event, button: .middle, action: .release, at: point)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    // MARK: - Wheel

    public override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let cell = cellHeight
        var lines: Int
        if event.hasPreciseScrollingDeltas {
            // A new gesture starts from zero; leftover sub-cell delta from the
            // previous flick must not carry into the opposite direction.
            if event.phase == .began || event.momentumPhase == .began { scrollAccumulator = 0 }
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / cell)
            scrollAccumulator -= CGFloat(lines) * cell
        } else {
            scrollAccumulator = 0
            lines = Int(event.scrollingDeltaY.rounded())
            if lines == 0 { lines = event.scrollingDeltaY > 0 ? 1 : -1 }
        }
        guard lines != 0 else { return }
        let up = lines > 0
        let magnitude = min(abs(lines), 100)

        let point = convert(event.locationInWindow, from: nil)
        if terminal.modes.mouseTracking != .none, !event.modifierFlags.contains(.shift) {
            for _ in 0..<magnitude {
                reportMouse(event: event, button: up ? .wheelUp : .wheelDown,
                            action: .press, at: point)
            }
            return
        }

        if terminal.isAlternate {
            // No scrollback to move: DECSET 1007 turns the wheel into cursor
            // keys so `less` and `man` scroll; otherwise the wheel does nothing.
            guard terminal.modes.alternateScroll else { return }
            let bytes = MouseEncoder.alternateScroll(
                up: up,
                lines: magnitude,
                applicationCursorKeys: terminal.modes.applicationCursorKeys)
            if !bytes.isEmpty { send(bytes, keystroke: false) }
            return
        }

        scrollViewport(by: up ? -magnitude : magnitude)
    }

    // MARK: - Reporting

    /// Send one mouse event to the program. Returns true when the program owns
    /// the pointer (so the caller must not select text), which is the case
    /// whenever tracking is on and ⇧ is not held — even for an event the
    /// encoder itself declines to spell.
    @discardableResult
    func reportMouse(event: NSEvent, button: MouseButton,
                     action: MouseAction, at point: CGPoint) -> Bool {
        guard terminal.modes.mouseTracking != .none else { return false }
        if event.modifierFlags.contains(.shift) { return false }

        let hit = hitTest(point: point)
        // Reports are viewport-relative (xterm): the row under the pointer,
        // not its distance from the top of the screen buffer.
        let screenRow = min(max(0, gridRow(at: point)), max(0, terminal.rows - 1))
        // xterm reports motion only when the pointer enters another cell.
        if action == .motion {
            if let last = lastReportedCell, last == (hit.col, screenRow) { return true }
            lastReportedCell = (hit.col, screenRow)
        } else {
            lastReportedCell = nil
        }
        var mods = KeyMapping.modifiers(from: event.modifierFlags)
        mods.remove(.locks)
        let scale = backingScale
        let mouseEvent = MouseEvent(button: button,
                                    action: action,
                                    modifiers: mods,
                                    col: hit.col,
                                    row: screenRow,
                                    pixelX: Int(point.x * scale),
                                    pixelY: Int(point.y * scale))
        if let bytes = MouseEncoder(terminal: terminal).encode(mouseEvent) {
            send(bytes, keystroke: false)
        }
        return true
    }

    // MARK: - Auto-scroll while dragging

    /// SwiftTerm's `calcScrollingVelocity`: the further past the edge, the
    /// faster, in four steps.
    func scrollingVelocity(_ delta: Int) -> Int {
        if delta > 9 { return max(terminal.rows / 2, 1) }
        if delta > 5 { return 3 }
        if delta > 2 { return 2 }
        return 1
    }

    func startAutoScroll() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, target: self,
                          selector: #selector(autoScrollTick(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.current.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDelta = 0
    }

    @objc func autoScrollTick(_ timer: Timer) {
        guard autoScrollDelta != 0, dragging else { stopAutoScroll(); return }
        let before = terminal.buffer.ydisp
        scrollViewport(by: autoScrollDelta)
        guard terminal.buffer.ydisp != before else { return }
        if let point = lastDragPoint {
            selection.extend(to: hitTest(point: point))
        }
        setNeedsFrame()
    }
}
