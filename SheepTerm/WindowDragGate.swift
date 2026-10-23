import AppKit

/// The view behind the tab strip that switches the window's dragging off
/// while the pointer is over the chips (TabStripView's NonWindowDraggingArea
/// has the why: the window server turns a chip drag into a window drag before
/// the app sees the mouse-down, and only `NSWindow.isMovable` stops it).
///
/// It switches dragging back on when the pointer leaves — and ALSO whenever
/// its own area changes under a pointer that is no longer inside it. Closing
/// the last tab with its × shrank the strip to nothing right under the
/// pointer: AppKit sent no mouse-exited for an area that vanished, so the
/// window stayed immovable until a new tab brought the strip back (a user
/// report, 5.0 (46)).
final class WindowDragGateView: NSView {
    private weak var trackedWindow: NSWindow?
    private var tracking: NSTrackingArea?
    /// Where the pointer is, in window coordinates. Tests replace it.
    var pointerInWindow: () -> NSPoint? = { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pointerInWindow = { [weak self] in self?.window?.mouseLocationOutsideOfEventStream }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        // The strip's own rect, not `.inVisibleRect`: with no tabs the strip
        // is zero-size and its visible rect came back as the WHOLE top bar,
        // so the pointer anywhere along the bar locked the window.
        if !area.isEmpty {
            let tracked = NSTrackingArea(rect: area, options: [.mouseEnteredAndExited, .activeAlways],
                                         owner: self, userInfo: nil)
            addTrackingArea(tracked)
            tracking = tracked
        }
        releaseIfPointerLeft()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        releaseIfPointerLeft()
    }

    override func viewDidHide() {
        super.viewDidHide()
        release()
    }

    override func mouseEntered(with event: NSEvent) { pointerEntered() }

    /// What a mouse-entered does: hold, but only for a pointer really over
    /// the strip.
    func pointerEntered() {
        guard let point = pointerInWindow(), area.contains(convert(point, from: nil)), !isHidden else { return }
        hold()
    }

    /// Where the strip is: its bounds, clipped to what is visible. Never the
    /// visible rect alone — that of a zero-size view is not empty.
    private var area: NSRect { bounds.intersection(visibleRect) }

    override func mouseExited(with event: NSEvent) { release() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Never leave a window immovable behind us.
        release()
        super.viewWillMove(toWindow: newWindow)
    }

    /// The pointer is over the chips: the window must not move.
    func hold() {
        window?.isMovable = false
        trackedWindow = window
    }

    /// Dragging back on, for the window this view switched off.
    func release() {
        trackedWindow?.isMovable = true
        trackedWindow = nil
    }

    /// The area moved or shrank: if the pointer is no longer inside it, the
    /// exit AppKit will not send is taken as sent.
    private func releaseIfPointerLeft() {
        guard trackedWindow != nil else { return }
        guard let point = pointerInWindow() else { release(); return }
        if isHidden || !area.contains(convert(point, from: nil)) { release() }
    }
}
