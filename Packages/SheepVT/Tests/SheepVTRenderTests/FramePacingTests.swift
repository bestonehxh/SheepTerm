// SheepVTRender — what the view does when a frame does NOT reach the screen.
//
// The paint path consumes its dirty state (`needsFrame`, the change counter,
// the viewport) on the assumption that the frame it is about to draw will be
// shown. It is not always: the surface ring can have nothing free, a drawable
// can be refused, an encoder can fail. A frame dropped after that bookkeeping
// was consumed is a frame nobody ever draws again — including the immediate
// paint a keystroke's echo rides on.
//
// No window is needed: `frameTick(now:)` is the display link's own body, and a
// `TerminalView` off-window still renders through the surface path (the tab a
// keystroke lands in has a window, but the pacing is the same). The tests that
// need a real machine skip themselves when there is no Metal device, the way
// `RendererTests` does.

import AppKit
import IOSurface
import Metal
import Testing
@testable import SheepVTRender
import SheepVT

@Suite("TerminalView frame pacing") @MainActor struct FramePacingTests {

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240), cols: 40, rows: 12)
    }

    /// Every test here needs a real renderer on the surface path — a machine
    /// without a Metal device, or an A/B run pinned to `SHEEPVT_LAYER=metal`,
    /// has nothing to present.
    private var canPresent: Bool { MTLCreateSystemDefaultDevice() != nil && TerminalView.useSurfaceLayer }

    @Test func aFrameThatDidNotPresentIsPaintedAtTheNextTick() {
        guard canPresent else { return }
        let view = makeView()
        let t = CACurrentMediaTime()
        view.frameTick(now: t)                      // the first frame lands
        #expect(!view.needsFrame)
        let shown = view.presentedFrames

        // The byte arrives and the frame carrying it is dropped.
        view.forceFailedFrames = 1
        view.feed("A")
        view.frameTick(now: t + 0.02)
        #expect(view.presentedFrames == shown)   // nothing reached a layer
        #expect(view.needsFrame)                             // so the repaint is still owed

        // The next tick draws it — before, this tick compared equal on the
        // change counter, decided nothing had changed, and the byte never
        // appeared until something else dirtied the view.
        view.frameTick(now: t + 0.04)
        #expect(view.presentedFrames == shown + 1)
        #expect(!view.needsFrame)                            // and is not owed for ever
    }

    /// The same across a run of dropped frames: the output is not lost, and
    /// nothing is left dirty once one frame does get through.
    @Test func outputSurvivesSeveralDroppedFramesAndLandsWhenTheRendererRecovers() {
        guard canPresent else { return }
        let view = makeView()
        let t = CACurrentMediaTime()
        view.frameTick(now: t)
        let shown = view.presentedFrames

        view.forceFailedFrames = 5
        view.feed("hello")
        for tick in 1...5 { view.frameTick(now: t + Double(tick) * 0.01) }
        #expect(view.presentedFrames == shown)
        #expect(view.needsFrame)

        view.frameTick(now: t + 0.06)
        #expect(view.presentedFrames == shown + 1)
        #expect(!view.needsFrame)
        #expect(view.terminal.screenLines().first == "hello")
    }

    /// A tab switched away is pulled out of the window. `releaseSurfaces` frees
    /// the ring, but the layer holds the surface it is showing all on its own —
    /// 14.06 MB of dirty IOSurface per hidden tab at 2560×1440, measured with
    /// vmmap, and this app is used with many tabs open.
    @Test func aHiddenViewLetsGoOfTheSurfaceItWasShowing() {
        guard canPresent else { return }
        let view = makeView()
        view.frameTick(now: CACurrentMediaTime())
        weak var surface = view.layer?.contents as? IOSurface
        #expect(surface != nil)                     // a frame is on the layer

        view.viewDidMoveToWindow()                  // window == nil: the tab is hidden
        #expect(view.layer?.contents == nil)
        #expect(surface == nil)                     // freed, not merely dropped from the ring
    }

    /// ...and the way back in paints inside the transaction that puts the view
    /// on screen, so emptying the layer cannot show as a flash of background.
    @Test func aTabComingBackPaintsBeforeItIsShown() {
        guard canPresent else { return }
        _ = NSApplication.shared                    // NSWindow needs the app object
        let view = makeView()
        view.feed("hello")
        view.frameTick(now: CACurrentMediaTime())
        view.viewDidMoveToWindow()
        #expect(view.layer?.contents == nil)

        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false         // no app runs here to own its lifetime
        window.contentView?.addSubview(view)        // AppKit calls viewDidMoveToWindow
        // Painted already, inside the same transaction — not left for the next
        // display-link tick. (`needsFrame` says nothing here: AppKit follows
        // the move with `viewDidChangeBackingProperties`, which asks for a
        // frame of its own.)
        #expect(view.layer?.contents != nil)
        view.removeFromSuperview()
    }

    /// AppKit's own display pass — a `needsDisplay` from anywhere: an
    /// appearance change, a hosting view's layout, a window coming back —
    /// used to replace the surface on the layer with a backing store of the
    /// view's own (empty) drawing. The view still believed its picture was
    /// current, so a tab switched back to sat blank until the next byte
    /// arrived and the user pressed Return to "wake it up". The layer's
    /// contents are ours: `layerContentsRedrawPolicy = .never` keeps AppKit's
    /// hands off them.
    @Test func appKitsDisplayPassLeavesThePictureAlone() {
        guard canPresent else { return }
        _ = NSApplication.shared
        let view = makeView()
        view.feed("hello")
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #expect(view.layer?.contents is IOSurface)

        view.needsDisplay = true
        view.displayIfNeeded()
        #expect(view.layer?.contents is IOSurface)
        view.removeFromSuperview()
    }

    /// And should the picture ever go missing from the layer while the view
    /// is on screen — whatever dropped it — the next tick notices and paints
    /// again, instead of comparing counters, seeing nothing new and leaving
    /// the terminal blank.
    @Test func aPictureDroppedFromTheLayerIsPaintedAgainAtTheNextTick() {
        guard canPresent else { return }
        _ = NSApplication.shared
        let view = makeView()
        view.feed("hello")
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        let t = CACurrentMediaTime()
        view.frameTick(now: t)
        #expect(!view.needsFrame)
        let shown = view.presentedFrames

        view.layer?.contents = nil                  // the picture is gone, the bookkeeping says "current"
        view.frameTick(now: t + 0.02)
        #expect(view.presentedFrames == shown + 1)
        #expect(view.layer?.contents is IOSurface)
        view.removeFromSuperview()
    }

    /// The other half of the deal: a repaint that is owed keeps the tick alive,
    /// but a renderer that never recovers must not be retried for ever. Half a
    /// second of one attempt per tick, then the link stops and waits for the
    /// next change like any idle view.
    @Test func aRendererThatNeverRecoversStopsBeingRetried() {
        guard canPresent else { return }
        _ = NSApplication.shared
        let view = makeView()
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        guard view.isTicking else { return }        // no display link in this environment

        // The clock is this test's own: everything below goes through
        // `frameTick(now:)` and `setNeedsFrame`, neither of which reads it.
        let t = CACurrentMediaTime()
        view.forceFailedFrames = 10_000
        view.setNeedsFrame()

        // Ten seconds after the last frame that was actually shown — well past
        // the idle stop — the repaint is owed, so the tick stays alive to try
        // again rather than parking the view on a stale picture.
        view.frameTick(now: t + 10)
        #expect(view.needsFrame)
        #expect(view.isTicking)

        // Half a second of that is enough. The view goes idle, still dirty, so
        // the next byte (or anything else that calls `setNeedsFrame`) starts
        // the link again and the frame is tried once more.
        view.frameTick(now: t + 10 + TerminalView.idleStop + 0.01)
        #expect(!view.isTicking)
        #expect(view.needsFrame)

        view.removeFromSuperview()
    }
}
