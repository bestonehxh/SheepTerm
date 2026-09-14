// SheepVTRender — the NSView.
//
// It owns a `Terminal` (it is that terminal's delegate), a `CAMetalLayer` and a
// `MetalRenderer`, and it turns AppKit events into the core's value types:
// `KeyEvent` for keys, `MouseEvent` for reporting, `Position` for selection.
// Nothing in here parses or paints — the core does the first, the renderer the
// second; this file is the wiring, the geometry and the frame pacing.
//
// Everything is main-actor (the target's default isolation), which is exactly
// how the app already drives the terminal: bytes arrive on a worker queue, hop
// to main once, and `feed` is called here.
//
// Layout rules that are load-bearing:
//   * the grid is anchored to the **top-left**; spare pixels are at the bottom
//     (`isFlipped` is true, so view y grows downward like the grid does),
//   * `cols = floor(width / cellWidth)`, `rows = floor(height / cellHeight)`,
//     never below 2 × 1,
//   * `sizeChanged` fires **only when the grid actually changed** — a font
//     change that keeps the same cols × rows must not reach the pty, or every
//     shell answers the window-size change with a fresh prompt.

import AppKit
import Metal
import QuartzCore

public final class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations {

    // MARK: - Core

    /// The emulator. The view is its delegate; feed it through `feed`.
    public let terminal: Terminal
    public let selection: Selection
    public let search: SearchEngine

    public weak var delegate: (any TerminalViewDelegate)?

    /// Default scrollback for a new view (the app overrides it from its
    /// `scrollbackLines` user default).
    public static var scrollbackLinesDefault = 10_000

    // MARK: - Appearance

    public var font: NSFont {
        didSet {
            guard font != oldValue else { return }
            rebuildFont()
        }
    }

    public var fontSmoothing: Bool {
        didSet {
            guard fontSmoothing != oldValue else { return }
            renderer?.fontSmoothing = fontSmoothing
            renderer?.invalidateRows()
            setNeedsFrame()
        }
    }

    public var colors: TerminalColors {
        didSet {
            guard colors != oldValue else { return }
            // Hand the theme to the core first: it is the baseline OSC 110/111/112
            // and RIS come back to, so a theme picked while a program holds an
            // override has to land there before the palette is rebuilt from it.
            pushHostColors()
            palette = Palette(colors: colors)
            palette.apply(overrides: terminal.palette)
            renderer?.palette = palette
            renderer?.invalidateRows()
            updateLayerBackground()
            setNeedsFrame()
        }
    }

    // MARK: - Highlighting (agent D's overlay)

    public var highlightProvider: (any HighlightProvider)? {
        didSet {
            if let highlightProvider {
                highlight = HighlightOverlay(provider: highlightProvider)
                highlight?.enabled = highlightEnabled
            } else {
                highlight = nil
            }
            renderer?.invalidateRows()
            setNeedsFrame()
        }
    }

    public var highlightEnabled = true {
        didSet {
            guard highlightEnabled != oldValue else { return }
            highlight?.enabled = highlightEnabled
            renderer?.invalidateRows()
            setNeedsFrame()
        }
    }

    private(set) var highlight: HighlightOverlay?

    // MARK: - Input options

    /// Option/Alt prefixes ESC (SwiftTerm's `optionAsMetaKey`). False lets the
    /// OS's own composed text through, so ⌥e é still types é.
    public var altSendsEscape = true
    /// Backspace sends 0x08 instead of DEL.
    public var backspaceSendsControlH = false
    /// Where `copy:` writes and `paste:` reads. Injectable so tests never touch
    /// the user's real pasteboard.
    public var pasteboard: NSPasteboard = .general

    // MARK: - Rendering

    private(set) var fontSet: FontSet
    private(set) var palette: Palette
    /// nil when the machine has no Metal device — the view still works, it just
    /// does not paint (every other behaviour, including tests, is unaffected).
    public private(set) var renderer: MetalRenderer?
    /// Test hook: pretend there is no Metal device.
    static var forceDisableMetal = false

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    /// IOSurface presentation (default) — `SHEEPVT_LAYER=metal` restores CAMetalLayer for A/B runs.
    static let useSurfaceLayer = ProcessInfo.processInfo.environment["SHEEPVT_LAYER"] != "metal"
    /// Pixel size the surface path renders at (bounds × backing scale).
    var surfacePixelSize = CGSize.zero

    // MARK: - Find / scroller

    private(set) var findBar: FindBar?
    public private(set) var currentMatch: SearchMatch?
    let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))

    // MARK: - Frame pacing

    private var displayLinkRef: CADisplayLink?
    /// Set while a repaint is owed — including a frame that was drawn but never
    /// presented. Readable (not settable) from outside the file so the tests
    /// can see that a dropped frame is still owed, and that it stops being owed
    /// once one is shown.
    private(set) var needsFrame = true
    private var lastChangeCounter: UInt64 = 0
    private var lastViewport = -1
    private var lastOverlayRevision: UInt64 = 0
    private var lastSelectionKey = SelectionKey()
    private var lastSearchKey: SearchMatch?
    /// Mode 2026: hold frames while the program is building one, but never for
    /// longer than this — a program that forgets to turn it off must not freeze
    /// the screen.
    static let synchronizedOutputHold: TimeInterval = 0.150
    var syncHoldUntil: CFTimeInterval = 0
    private var syncPresentUntil: CFTimeInterval = 0
    private var lastFeedTime: CFTimeInterval = 0
    private var lastRenderedGlyphs: UInt64 = 0
    private var burstStart: CFTimeInterval = 0
    /// When the current unbroken run of held frames began; 0 = not holding.
    private var holdStart: CFTimeInterval = 0
    var cursorBlinkOn = true
    private var lastBlinkToggle: CFTimeInterval = 0
    static let cursorBlinkInterval: CFTimeInterval = 0.5
    /// Keep the display link for this long after the last paint: re-creating
    /// it costs a frame of latency on the next keystroke.
    static let idleStop: CFTimeInterval = 0.5

    // MARK: - Mouse / selection gesture state

    var dragAnchor: Position?

    var dragStartPoint: CGPoint?

    var lastReportedCell: (Int, Int)?
    var dragMode: Selection.Mode = .character
    var dragging = false
    var lastDragPoint: CGPoint?
    var autoScrollTimer: Timer?
    var autoScrollDelta = 0
    var scrollAccumulator: CGFloat = 0

    // MARK: - IME

    var markedText = ""
    var markedSelectedRange = NSRange(location: 0, length: 0)
    private var preedit: NSTextField?

    private var configured = false

    // MARK: - Init

    public init(frame: CGRect,
                cols: Int = 80,
                rows: Int = 24,
                scrollback: Int = TerminalView.scrollbackLinesDefault) {
        let f = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        font = f
        fontSmoothing = false
        colors = .sheepTerm
        fontSet = FontSet(font: f, scale: 2)
        var p = Palette(colors: .sheepTerm)
        p.apply(overrides: Array(repeating: nil, count: 256))
        palette = p
        terminal = Terminal(cols: cols, rows: rows, scrollback: scrollback)
        selection = Selection(terminal: terminal)
        search = SearchEngine(terminal: terminal)
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        let f = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        font = f
        fontSmoothing = false
        colors = .sheepTerm
        fontSet = FontSet(font: f, scale: 2)
        palette = Palette(colors: .sheepTerm)
        terminal = Terminal(cols: 80, rows: 24, scrollback: TerminalView.scrollbackLinesDefault)
        selection = Selection(terminal: terminal)
        search = SearchEngine(terminal: terminal)
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        terminal.delegate = self
        pushHostColors()

        if !TerminalView.forceDisableMetal, let device = MTLCreateSystemDefaultDevice() {
            metalLayer?.device = device
            renderer = try? MetalRenderer(device: device)
        }
        rebuildFont(resizeGrid: false)
        renderer?.palette = palette
        renderer?.fontSmoothing = fontSmoothing
        updateLayerBackground()

        scroller.scrollerStyle = .overlay
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        scroller.isHidden = true
        scroller.autoresizingMask = [.minXMargin, .height]
        addSubview(scroller)

        configured = true
        updateGrid()
        setNeedsFrame()
    }

    // MARK: - Layer

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Present inside the CA transaction always, not only while resizing: an
    /// asynchronous CAMetalLayer present reaches the compositor one vsync later
    /// than a layer committed with the transaction (measured key→pixel: 47 ms
    /// vs Terminal.app's 25 ms). Our frames take 1–3 ms of GPU, so waiting for
    /// them on the main thread costs nothing noticeable.
    /// `SHEEPVT_ASYNC_PRESENT=1` switches the old behaviour back on for A/B runs.
    static let alwaysPresentWithTransaction = ProcessInfo.processInfo.environment["SHEEPVT_ASYNC_PRESENT"] != "1"

    public override func makeBackingLayer() -> CALayer {
        if TerminalView.useSurfaceLayer {
            let layer = CALayer()
            layer.isOpaque = true
            layer.contentsGravity = .topLeft
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            return layer
        }
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = TerminalView.alwaysPresentWithTransaction
        let env = ProcessInfo.processInfo.environment
        layer.maximumDrawableCount = Int(env["SHEEPVT_DRAWABLES"] ?? "") ?? 2
        if env["SHEEPVT_DISPLAYSYNC"] == "0" { layer.displaySyncEnabled = false }
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.allowsNextDrawableTimeout = true
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    var backingScale: CGFloat { window?.backingScaleFactor ?? metalLayer?.contentsScale ?? 2 }

    /// Hand the theme to the core as the baseline for the default colours:
    /// what `OSC 10/11/12 ?` answers with while nothing has overridden them,
    /// and what `OSC 110/111/112` and RIS restore. Writing these is the host's
    /// move by definition — see `Terminal.defaultForeground`.
    private func pushHostColors() {
        terminal.defaultForeground = colors.foreground
        terminal.defaultBackground = colors.background
        terminal.defaultCursorColor = colors.cursor
    }

    /// `Terminal.defaultColorGeneration` as of the last sync — see
    /// `syncDefaultColors`. Starts at a fresh terminal's value, so an OSC that
    /// arrives before the first frame is still a difference.
    private var appliedDefaultColorGeneration: UInt64 = 0

    /// Follow the core's default colours into the two places the renderer's own
    /// sync of the same counter does not reach: the layer's backdrop (the
    /// margins, and the instant before a frame lands) and the cursor colour,
    /// which is `OSC 12`'s and lives in the palette rather than in the frame.
    /// Called at the top of `renderFrame`, so the palette pushed here is the
    /// one the renderer is about to encode from.
    private func syncDefaultColors() {
        guard terminal.defaultColorGeneration != appliedDefaultColorGeneration else { return }
        appliedDefaultColorGeneration = terminal.defaultColorGeneration
        updateLayerBackground()
        var c = palette.colors
        // fg/bg as well as the cursor, so the palette we hand over is right on
        // its own: the renderer copies fg/bg out of the core too, but only when
        // its own counter is behind, and this must not depend on that order.
        c.foreground = terminal.defaultForeground
        c.background = terminal.defaultBackground
        c.cursor = terminal.defaultCursorColor
        guard c != palette.colors else { return }
        palette.colors = c
        palette.apply(overrides: terminal.palette)
        renderer?.palette = palette
        renderer?.invalidateRows()
    }

    private func updateLayerBackground() {
        // The colour in effect, not the theme's: a program that set its own
        // background with OSC 11 must not leave a theme-coloured frame around
        // the picture (and after OSC 111 the theme has to come back).
        let rgb = terminal.defaultBackground
        layer?.backgroundColor = CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                              green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                              blue: CGFloat(rgb & 0xFF) / 255,
                                              alpha: 1)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = backingScale
        rebuildFont()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer?.contentsScale = backingScale
        if window == nil {
            stopDisplayLink()
            stopAutoScroll()
            // A hidden tab keeps its terminal but not three screen-sized
            // IOSurfaces (14.06 MB each at 2560×1440); they come back on the
            // first frame after the tab is shown again.
            renderer?.releaseSurfaces()
            // The ring is gone, but the layer holds a reference of its own to
            // the surface it is showing: measured with vmmap, eight hidden tabs
            // at 2560×1440 kept 112.5 MB of dirty IOSurface after
            // `releaseSurfaces` and none after this line — one whole surface
            // per tab, for a picture nobody can see. Nothing can flash: the
            // view is out of the window here, and the way back in paints inside
            // the transaction that puts it on screen (below).
            if let layer, metalLayer == nil { SurfacePresenter.clear(layer) }
        } else {
            updateGrid()
            // Draw NOW rather than asking for a frame: the layer was emptied on
            // the way out, and a `setNeedsFrame` alone would leave the tab
            // showing a flat background colour until the display link came
            // round. `presentSynchronously` leaves the view dirty when it could
            // not draw (the degenerate frame a tab is handed on the way in), so
            // the tick still catches that case.
            presentSynchronously()
        }
    }

    // MARK: - Geometry

    public var cols: Int { terminal.cols }
    public var rows: Int { terminal.rows }
    public var cellWidth: CGFloat { max(1, fontSet.metrics.width) }
    public var cellHeight: CGFloat { max(1, fontSet.metrics.height) }

    private func rebuildFont(resizeGrid: Bool = true) {
        fontSet = FontSet(font: font, scale: backingScale)
        renderer?.fontSet = fontSet
        renderer?.invalidateRows()
        if resizeGrid { updateGrid() }
        setNeedsFrame()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    public override func layout() {
        super.layout()
        layoutOverlays()
    }

    private func layoutOverlays() {
        let width = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: bounds.width - width, y: 0,
                                width: width, height: bounds.height)
        if let findBar, !findBar.isHidden {
            let w = min(FindBar.barWidth, max(160, bounds.width - 24))
            findBar.frame = NSRect(x: bounds.width - w - width - 6, y: 6,
                                   width: w, height: FindBar.barHeight)
        }
        positionPreedit()
    }

    /// Recompute cols × rows from the frame and the cell size; resize the
    /// terminal and tell the host **only when the grid changed**.
    func updateGrid() {
        guard configured else { return }
        // A tab that is switched away is pulled out of the window, and on the
        // way out (and back in) SwiftUI hands the view degenerate frames. A
        // 0×0 view is not a 2×1 terminal: resizing to it (and telling the
        // device) scrambled the session — the cursor came back near the top
        // and new output overwrote the banner. Keep the grid until a real
        // size arrives.
        guard bounds.width >= cellWidth * CGFloat(Terminal.minCols),
              bounds.height >= cellHeight * CGFloat(Terminal.minRows) else { return }
        let c = max(Terminal.minCols, Int(floor(bounds.width / cellWidth)))
        let r = max(Terminal.minRows, Int(floor(bounds.height / cellHeight)))
        let drawableChanged = updateDrawableSize()
        layoutOverlays()
        // The frame changed under us (live resize, the full-screen animation, a
        // split): draw the new size NOW, inside this layout pass, or Core
        // Animation stretches the previous drawable to the new bounds until
        // the display link gets around to it — visibly rubbery text.
        defer { if drawableChanged { presentSynchronously() } }
        guard c != terminal.cols || r != terminal.rows else { return }
        terminal.resize(cols: c, rows: r)
        // Reflow renumbers every line: positions taken before it mean nothing.
        selection.clear()
        search.invalidate()
        currentMatch = nil
        highlight?.invalidate()
        renderer?.invalidateRows()
        setNeedsFrame()
        delegate?.sizeChanged(self, cols: c, rows: r)
    }

    /// Returns true when the drawable size actually changed.
    @discardableResult
    private func updateDrawableSize() -> Bool {
        let scale = backingScale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        guard let metalLayer else {
            layer?.contentsScale = scale
            guard surfacePixelSize != size else { return false }
            surfacePixelSize = size
            return true
        }
        metalLayer.contentsScale = scale
        guard metalLayer.drawableSize != size else { return false }
        metalLayer.drawableSize = size
        return true
    }

    /// Render and present within the current CA transaction (Ghostty's
    /// resize trick): `presentsWithTransaction` makes the new drawable land in
    /// the same frame as the new bounds. It costs a GPU wait on the main
    /// thread, so it is switched back off once the size has settled.
    private func presentSynchronously() {
        guard window != nil, renderer != nil else { return }
        if let metalLayer {
            metalLayer.presentsWithTransaction = true
            syncPresentUntil = CACurrentMediaTime() + 0.4
        }
        // The surface path is synchronous by construction: the new contents
        // are set inside this very transaction.
        if renderFrame() {
            lastChangeCounter = terminal.changeCounter
            lastViewport = terminal.buffer.ydisp
            needsFrame = false
            lastPresentTime = CACurrentMediaTime()
            retryUntil = 0
        } else {
            // Nothing was shown (a tab on its way back in is handed a 0×0
            // frame first): stay dirty so the tick draws it when it can.
            needsFrame = true
        }
        startDisplayLink()
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer?.presentsWithTransaction = true
        syncPresentUntil = .infinity
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        syncPresentUntil = CACurrentMediaTime() + 0.4
        setNeedsFrame()
    }

    // MARK: - Feeding

    public func feed(_ bytes: [UInt8]) {
        noteFeed()
        terminal.feed(bytes)
        paintNow()
    }

    public func feed(_ text: String) {
        noteFeed()
        terminal.feed(text)
        paintNow()
    }

    /// Draw the output that just landed, unless a paint went out a moment ago
    /// (the tick will catch this one). Always keeps the tick alive as a backstop.
    private func paintNow() {
        // Not `needsFrame = true`: output is detected through `changeCounter`
        // (so the erase-hold can still apply); `needsFrame` is for UI changes.
        let now = CACurrentMediaTime()
        // Output that answers a keystroke is painted at once whatever the
        // rate limit says: echo latency is the one number people feel.
        let answeringAKey = now - lastKeySentTime < 0.3
        if window != nil, renderer != nil, answeringAKey || now - lastPaintTime >= TerminalView.immediatePaintGap {
            paintIfNeeded(now: now)
        }
        startDisplayLink()
    }

    /// Bookkeeping for the foot-style coalescing in `frameTick`: a page of
    /// device output arrives as several SSH packets a few hundred µs apart,
    /// and drawing each one as it lands shows the page assembling line by
    /// line (and the pager prompt blinking out before the page replaces it).
    private func noteFeed() {
        let now = CACurrentMediaTime()
        // A burst ends only after a real pause; chunks a few ms apart are one burst.
        if now - lastFeedTime > TerminalView.burstGap { burstStart = now }
        lastFeedTime = now
    }
    /// Chunks closer than this belong to one burst (packets of a page arrive 1–5 ms
    /// apart over a VPN; the device pauses 20–46 ms between erasing a pager prompt
    /// and sending the page — measured on an Aruba CX).
    static let burstGap: CFTimeInterval = 0.060
    /// How long a burst that only erased/moved the cursor may wait for text to follow.
    static let eraseHold: CFTimeInterval = 0.080
    /// Ceiling on a run of consecutive holds, whatever the burst does. Two and
    /// a half holds: long enough that the case it exists for (an erase, then
    /// the text that replaces it) is never split, short enough that a
    /// pathological stream costs a visible stutter and not a frozen screen.
    static let maxEraseHold: CFTimeInterval = 0.200

    /// Write bytes to the device, as if the user had typed them.
    /// Write bytes to the device. `keystroke` marks bytes the user typed: only
    /// those restart the cursor blink, arm the "answering a key" fast paint
    /// and feed the erase-hold heuristic. Mouse reports, pastes and the
    /// terminal's own replies (DA, DSR…) pass `false` — a mouse move in vim
    /// must not open a 300 ms render-storm window or disarm the hold.
    public func send(_ bytes: [UInt8], keystroke: Bool = true) {
        guard keystroke else { delegate?.send(self, bytes: bytes); return }
        lastKeySentTime = CACurrentMediaTime()
        // Typing restarts the blink with the cursor ON, so a keystroke that
        // prints nothing visible (Space) still shows the cursor move at once
        // instead of after the off-phase ends (Terminal.app does the same).
        if !cursorBlinkOn { cursorBlinkOn = true; needsFrame = true }
        lastBlinkToggle = lastKeySentTime
        // Printable text, Space or Return: what follows is a redraw/echo the
        // erase-hold may wait for. Anything else (Backspace, Delete, arrows,
        // control chars, escape sequences) expects its erase to show at once.
        // LF is here for LNM (`CSI 20 h`), where Return sends CR LF: it is the
        // same keypress, and leaving it out meant the erase-hold stopped
        // working after every Enter in that mode.
        lastKeyWasPrintable = bytes.count <= 4
            && bytes.allSatisfy { $0 == 0x0D || $0 == 0x0A || ($0 >= 0x20 && $0 != 0x7F) }
        delegate?.userTyped(self)
        delegate?.send(self, bytes: bytes)
    }
    private var lastKeySentTime: CFTimeInterval = 0
    private var lastKeyWasPrintable = false

    // MARK: - Scrollback

    public func clearScrollback() {
        // The primary buffer owns the scrollback; on the alt screen (vim,
        // less) `buffer` is the alternate one, which has none to clear.
        terminal.primary.clearScrollback()
        selection.clear()
        search.invalidate()
        currentMatch = nil
        highlight?.invalidate()
        renderer?.invalidateRows()
        terminal.markAllDirty()
        setNeedsFrame()
        delegate?.scrolled(self)
    }

    public func scrollToBottom() {
        guard terminal.buffer.ydisp != terminal.buffer.ybase else { return }
        terminal.scrollViewportToBottom()
        setNeedsFrame()
        delegate?.scrolled(self)
    }

    public func scrollViewport(by lines: Int) {
        guard lines != 0 else { return }
        let before = terminal.buffer.ydisp
        terminal.scrollViewport(by: lines)
        guard terminal.buffer.ydisp != before else { return }
        setNeedsFrame()
        delegate?.scrolled(self)
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        let b = terminal.buffer
        guard b.ybase > 0 else { return }
        switch sender.hitPart {
        case .knob, .knobSlot:
            let target = Int((sender.doubleValue * Double(b.ybase)).rounded())
            scrollViewport(by: target - b.ydisp)
        case .decrementPage:
            scrollViewport(by: -terminal.rows)
        case .incrementPage:
            scrollViewport(by: terminal.rows)
        case .decrementLine:
            scrollViewport(by: -1)
        case .incrementLine:
            scrollViewport(by: 1)
        default:
            break
        }
    }

    private func updateScroller() {
        let b = terminal.buffer
        let total = b.ybase + terminal.rows
        if b.ybase <= 0 || terminal.isAlternate {
            scroller.isHidden = true
            return
        }
        scroller.isHidden = false
        scroller.knobProportion = CGFloat(terminal.rows) / CGFloat(max(1, total))
        scroller.doubleValue = Double(b.ydisp) / Double(max(1, b.ybase))
    }

    // MARK: - Selection

    public var hasSelection: Bool { selection.isActive && selection.start != nil }
    public var selectedText: String { selection.text() }

    /// The cell under a point in view coordinates, clamped to the grid.
    public func hitTest(point: CGPoint) -> Position {
        let col = min(max(0, Int(floor(point.x / cellWidth))), max(0, terminal.cols - 1))
        let row = min(max(0, gridRow(at: point)), max(0, terminal.rows - 1))
        return Position(line: terminal.buffer.lineNumber(ofViewportRow: row), col: col)
    }

    /// The viewport row a point falls on, **not** clamped — negative above the
    /// view, ≥ rows below it, which is what the auto-scroll needs.
    func gridRow(at point: CGPoint) -> Int {
        Int(floor(point.y / cellHeight))
    }

    // MARK: - Frames

    /// Ask for a repaint (new bytes, overlay revision moved, theme change…).
    public func setNeedsFrame() {
        needsFrame = true
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard window != nil, displayLinkRef == nil else { return }
        let link = displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .current, forMode: .common)
        displayLinkRef = link
    }

    isolated deinit {
        displayLinkRef?.invalidate()
        autoScrollTimer?.invalidate()
    }

    /// Whether the tick is still running — the tests watch it to see that a
    /// renderer which never recovers stops being asked for frames.
    var isTicking: Bool { displayLinkRef != nil }

    private func stopDisplayLink() {
        displayLinkRef?.invalidate()
        displayLinkRef = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        frameTick(now: CACurrentMediaTime())
    }

    /// One tick, without a display link — the tick's own body, so the tests can
    /// drive the pacing (no window means no display link).
    func frameTick(now: CFTimeInterval) {
        if !TerminalView.alwaysPresentWithTransaction,
           let metalLayer, metalLayer.presentsWithTransaction, !inLiveResize, now > syncPresentUntil {
            metalLayer.presentsWithTransaction = false
        }
        if !paintIfNeeded(now: now) {
            // Idling out is measured in REAL TIME, never in ticks: on a 120 Hz
            // display a frame count large enough to survive the 500 ms blink
            // period would keep the link alive far too long on a 60 Hz one, and
            // a small one would stop it before the cursor ever toggled. So the
            // link stays while blinking, and otherwise idles out on the clock.
            if !shouldBlink {
                // A frame that could not be shown is still owed, so the link
                // keeps ticking past the idle stop — but only until the retry
                // deadline, or a renderer that never recovers would hold a
                // display link for ever.
                if now > retryUntil, now - lastPresentTime > TerminalView.idleStop { stopDisplayLink() }
            }
        }
    }

    /// Paint when something changed. Shared by the display-link tick and the
    /// immediate path in `feed`: output is drawn the moment it lands (like
    /// Terminal.app), not at the next tick — that wait cost half a frame on
    /// average, and the present after it another one. The tick still runs for
    /// blink, selection, scroll and anything the immediate path rate-limited.
    @discardableResult
    private func paintIfNeeded(now: CFTimeInterval) -> Bool {
        if now < syncHoldUntil { return false }

        var changed = needsFrame
        if terminal.changeCounter != lastChangeCounter {
            let viewportMoved = terminal.buffer.ydisp != lastViewport
            // Nothing visible was printed — the device erased something (a
            // pager prompt, a line being redrawn) and, measured on a real
            // switch, pauses 20–46 ms before the text that replaces it. Hold
            // the frame so the screen does not blink blank in between. Only
            // after a printable key / Space / Return: an erase that follows
            // Backspace, Delete or an arrow IS the response and must show at
            // once. Typing echo prints a glyph, so it is never held either.
            // No other coalescing: every tick with output paints (echo
            // latency = one vsync), the way Ghostty and Terminal.app do it.
            // `needsFrame` here means something other than output wants a
            // repaint (theme, selection, find bar) — never hold those.
            if !needsFrame, !viewportMoved,
               lastKeyWasPrintable, now - lastKeySentTime < 1.0,
               terminal.visibleGlyphsPrinted == lastRenderedGlyphs,
               now - burstStart < TerminalView.eraseHold {
                // Each hold is bounded by `eraseHold` from the START OF THE
                // BURST, and a burst restarts after a 60 ms gap — so a stream
                // of glyph-less chunks spaced just wider than that gap renews
                // the window for ever and the screen never repaints. A
                // simulation held it 3 s solid. Real output almost always
                // prints a glyph, and letting go of the keyboard for a second
                // releases it, but "almost always" is not a bound.
                if holdStart == 0 { holdStart = now }
                if now - holdStart < TerminalView.maxEraseHold { return false }
            }
            holdStart = 0
            changed = true
        }
        if terminal.buffer.ydisp != lastViewport { changed = true }
        if let highlight, highlight.revision != lastOverlayRevision { changed = true }
        let selKey = SelectionKey(selection)
        if selKey != lastSelectionKey { changed = true }
        if currentMatch != lastSearchKey { changed = true }

        if shouldBlink {
            if now - lastBlinkToggle >= TerminalView.cursorBlinkInterval {
                lastBlinkToggle = now
                cursorBlinkOn.toggle()
                changed = true
            }
        } else if !cursorBlinkOn {
            cursorBlinkOn = true
            changed = true
        }

        if changed {
            // Everything below is consumed on the assumption that the frame is
            // shown. When it is not — no drawable, no free surface, an encoder
            // that failed — the next tick would compare equal, decide nothing
            // changed and drop the frame for good, keystroke echo included. So
            // remember what was consumed and put it back if nothing was shown.
            let consumed = (glyphs: lastRenderedGlyphs, counter: lastChangeCounter, viewport: lastViewport,
                            overlay: lastOverlayRevision, selection: lastSelectionKey, search: lastSearchKey)
            lastRenderedGlyphs = terminal.visibleGlyphsPrinted
            lastChangeCounter = terminal.changeCounter
            lastViewport = terminal.buffer.ydisp
            lastOverlayRevision = highlight?.revision ?? 0
            lastSelectionKey = selKey
            lastSearchKey = currentMatch
            needsFrame = false
            // The *attempt* is what rate-limits the immediate path, shown or
            // not: a renderer that keeps failing must not be asked to draw once
            // per chunk of output that lands.
            lastPaintTime = now
            guard renderFrame() else {
                lastRenderedGlyphs = consumed.glyphs
                lastChangeCounter = consumed.counter
                lastViewport = consumed.viewport
                lastOverlayRevision = consumed.overlay
                lastSelectionKey = consumed.selection
                lastSearchKey = consumed.search
                needsFrame = true
                // Half a second of retries, one per display-link tick — long
                // enough for a compositor that is holding every surface (a
                // frame or two) and for the first frame after a long idle,
                // short enough that a renderer which never recovers stops
                // being asked. Only the start of a run of failures sets it, so
                // failing frames cannot keep pushing the deadline out.
                if retryUntil == 0 { retryUntil = now + TerminalView.idleStop }
                // Reported as "did not paint" so the tick counts it as idle.
                return false
            }
            retryUntil = 0
            lastPresentTime = now
            return true
        }
        return false
    }
    private var lastPaintTime: CFTimeInterval = 0
    /// When a frame last actually reached a layer. The idle stop runs off this
    /// rather than off `lastPaintTime`, which now also counts attempts: a
    /// render that never presents re-arms `needsFrame`, and if its attempts
    /// kept the link alive the view would repaint for ever.
    private var lastPresentTime: CFTimeInterval = 0
    /// Deadline for the current run of frames that would not present; 0 while
    /// frames are landing. Read by the tick's idle stop.
    private var retryUntil: CFTimeInterval = 0
    /// Immediate paints are rate-limited to about two per frame; the tick
    /// picks up whatever lands in between.
    static let immediatePaintGap: CFTimeInterval = 0.008

    private var shouldBlink: Bool {
        guard isFocused, terminal.cursorVisible else { return false }
        switch terminal.cursorStyle {
        case .blinkBlock, .blinkUnderline, .blinkBar: return true
        default: return terminal.modes.cursorBlink
        }
    }

    var isFocused: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Build the overlay and hand one frame to the renderer. **Returns false
    /// when the frame did not reach a layer** — no Metal device, a degenerate
    /// drawable size, or (the case that costs a keystroke) a present the
    /// renderer had to drop because no drawable or no free surface was
    /// available. `paintIfNeeded` re-arms itself on false, so the frame is
    /// tried again instead of being dropped for good.
    @discardableResult
    func renderFrame() -> Bool {
        let t0 = CACurrentMediaTime()
        syncDefaultColors()
        updateScroller()
        updateFindStatus()
        guard let renderer else { return false }
        if forceFailedFrames > 0 { forceFailedFrames -= 1; return false }
        let presented: Bool
        if let metalLayer {
            guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return false }
            // Both paths answer whether a frame actually reached the layer:
            // a dropped drawable (A/B fallback) and a surface the compositor
            // would not give up are the same fact to the caller — this frame
            // was not shown, so the dirty state has to survive it.
            presented = renderer.render(terminal: terminal, overlay: makeOverlay(),
                                        layer: metalLayer, scale: backingScale)
        } else if let layer, surfacePixelSize.width >= 1 {
            presented = renderer.render(terminal: terminal, overlay: makeOverlay(), surfaceLayer: layer,
                                        pixelSize: surfacePixelSize, scale: backingScale)
        } else {
            return false
        }
        if TerminalView.frameLog {
            let t1 = CACurrentMediaTime()
            let stats = renderer.lastFrameStats
            let gap = lastFrameLogTime == 0 ? 0 : (t0 - lastFrameLogTime) * 1000
            lastFrameLogTime = t0
            frameLogCount += 1
            frameLogTotal += t1 - t0
            if TerminalView.frameLogAll || t1 - t0 > 0.012 || frameLogCount % 30 == 0 {
                let sinceKey = t0 - lastKeySentTime
                let keyNote = sinceKey < 0.5 ? String(format: "  key→frame %.1f ms", sinceKey * 1000) : ""
                FileHandle.standardError.write(String(format: "[frame %4d] gap %6.1f ms  render %5.1f ms  rows rebuilt %d cached %d glyphs %d  avg %.2f ms%@\n",
                    frameLogCount, gap, (t1 - t0) * 1000, stats.rowsRebuilt, stats.rowsCached, stats.glyphsRasterised,
                    frameLogTotal / Double(frameLogCount) * 1000, keyNote).data(using: .utf8)!)
            }
        }
        if presented { presentedFrames &+= 1 }
        return presented
    }

    /// Frames this view has actually put on a layer. The tests read it as a
    /// delta around their own ticks to tell a frame that was shown from one
    /// the ring or the encoder had to drop.
    private(set) var presentedFrames: UInt64 = 0

    /// Test hook: report this many upcoming frames as "did not present", which
    /// is what a dropped drawable or a ring with no free surface looks like
    /// from here. Nothing in the app sets it.
    var forceFailedFrames = 0

    /// `SHEEPVT_FRAMELOG=1` prints per-frame timing to stderr (slow frames and every 30th).
    static let frameLog = ProcessInfo.processInfo.environment["SHEEPVT_FRAMELOG"] != nil
    static let frameLogAll = ProcessInfo.processInfo.environment["SHEEPVT_FRAMELOG"] == "2"
    private var lastFrameLogTime: CFTimeInterval = 0
    private var frameLogCount = 0
    private var frameLogTotal: CFTimeInterval = 0

    func makeOverlay() -> FrameOverlay {
        var overlay = FrameOverlay()
        overlay.selection = selection.isActive ? selection : nil
        if search.isValid {
            overlay.searchMatches = search.findAll()
            overlay.currentMatch = currentMatch
        }
        overlay.highlight = (highlightEnabled && !terminal.isAlternate) ? highlight : nil
        overlay.cursorVisible = terminal.cursorVisible && terminal.buffer.ydisp == terminal.buffer.ybase
        overlay.cursorBlinkOn = shouldBlink ? cursorBlinkOn : true
        overlay.focused = isFocused
        overlay.reverseVideo = terminal.modes.reverseVideo
        return overlay
    }

    // MARK: - Focus

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            cursorBlinkOn = true
            lastBlinkToggle = CACurrentMediaTime()
            if terminal.modes.focusEvents { send(KeyEncoder.focus(true), keystroke: false) }
            setNeedsFrame()
        }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            if terminal.modes.focusEvents { send(KeyEncoder.focus(false), keystroke: false) }
            setNeedsFrame()
        }
        return ok
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Responder actions

    @objc public func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        pasteText(text)
    }

    /// Paste `text` the way a paste should reach the device — after the host's
    /// SafePaste veto, CR for newlines, bracketed when the program asked.
    public func pasteText(_ text: String) {
        guard delegate?.shouldPaste(self, text: text) ?? true else { return }
        send(KeyEncoder.paste(text, bracketed: terminal.modes.bracketedPaste), keystroke: false)
        scrollToBottom()
    }

    @objc public override func selectAll(_ sender: Any?) {
        selection.selectAll()
        setNeedsFrame()
    }

    @objc public func clearScrollback(_ sender: Any?) {
        clearScrollback()
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(paste(_:)):
            return pasteboard.string(forType: .string) != nil
        default:
            return true
        }
    }

    // MARK: - Find

    public override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        switch action {
        case .showFindInterface: showFind()
        case .hideFindInterface: hideFind()
        case .nextMatch: findNext()
        case .previousMatch: findPrevious()
        case .setSearchString: useSelectionForFind()
        default: break
        }
    }

    public func showFind() {
        let bar: FindBar
        if let findBar {
            bar = findBar
        } else {
            bar = FindBar(frame: NSRect(x: 0, y: 0, width: FindBar.barWidth, height: FindBar.barHeight))
            bar.onChange = { [weak self] bar in self?.findBarChanged(bar) }
            bar.onNext = { [weak self] _ in self?.findNext() }
            bar.onPrevious = { [weak self] _ in self?.findPrevious() }
            bar.onClose = { [weak self] _ in self?.hideFind() }
            addSubview(bar)
            findBar = bar
        }
        bar.isHidden = false
        if hasSelection {
            let text = selectedText
            // `isNewline`, not `contains("\n")`: CRLF is ONE Character and
            // equals neither "\n" nor "\r", so a selection copied out of a
            // Windows-formatted screen seeded the find bar with a multi-line
            // string (which matches nothing).
            if !text.isEmpty, !text.contains(where: { $0.isNewline }) { bar.searchText = text }
        } else if bar.searchText != search.term {
            bar.searchText = search.term
        }
        layoutOverlays()
        bar.focusSearchField()
        updateFindStatus()
    }

    public func hideFind() {
        findBar?.isHidden = true
        // Closing the bar drops the search: otherwise every match stays
        // tinted and the scrollback is re-searched on every frame of output.
        search.term = ""
        currentMatch = nil
        renderer?.invalidateRows()
        window?.makeFirstResponder(self)
        setNeedsFrame()
    }

    private func findBarChanged(_ bar: FindBar) {
        search.term = bar.searchText
        search.options = bar.options
        currentMatch = nil
        // From the viewport, not from the top of the scrollback. `findNext`
        // with no current match means "start from the beginning", so every
        // keystroke in the find field threw the view 10,000 lines up to the
        // oldest match in the buffer — while the line being looked for was
        // almost always the one on screen. Now the first hit is the first one
        // at or below what is being read, and it still wraps to the top when
        // there is nothing below.
        if search.isValid { moveMatch(forward: true, from: viewportAnchor) }
        else { updateFindStatus(); setNeedsFrame() }
    }

    /// Just before the first visible cell: `findNext(after:)` is strict, and a
    /// match at column 0 of the top visible line must count as "below" this.
    private var viewportAnchor: Position {
        Position(line: terminal.buffer.lineNumber(atIndex: terminal.buffer.ydisp), col: -1)
    }

    public func findNext() {
        moveMatch(forward: true)
    }

    public func findPrevious() {
        moveMatch(forward: false)
    }

    private func moveMatch(forward: Bool, from anchor: Position? = nil) {
        guard search.isValid else { currentMatch = nil; updateFindStatus(); return }
        let all = search.findAll()
        guard !all.isEmpty else { currentMatch = nil; updateFindStatus(); setNeedsFrame(); return }
        let from = anchor ?? currentMatch?.start
        let next: SearchMatch?
        if forward {
            next = search.findNext(after: from) ?? all.first
        } else {
            next = search.findPrevious(before: from) ?? all.last
        }
        currentMatch = next
        if let next { scrollIntoView(next) }
        updateFindStatus()
        setNeedsFrame()
    }

    public func useSelectionForFind() {
        let text = selectedText
        guard !text.isEmpty else { showFind(); return }
        search.term = text
        currentMatch = nil
        showFind()
        findBar?.searchText = text
    }

    private func scrollIntoView(_ match: SearchMatch) {
        let b = terminal.buffer
        guard let index = b.index(ofLine: match.start.line) else { return }
        let top = b.ydisp
        let bottom = b.ydisp + terminal.rows - 1
        if index < top {
            scrollViewport(by: index - top)
        } else if index > bottom {
            scrollViewport(by: index - bottom)
        }
    }

    private func updateFindStatus() {
        guard let findBar, !findBar.isHidden else { return }
        guard search.isValid else {
            // `isValid` is what compiles the pattern, so the reason it was
            // refused is only readable after it.
            findBar.setMatchCount(current: nil, total: 0, problem: search.regexProblem)
            return
        }
        let all = search.findAll()
        // The index only means something inside the painted set: past the limit
        // the match the user is standing on is real but unnumbered.
        let index = currentMatch.flatMap { m in all.firstIndex(where: { $0 == m }).map { $0 + 1 } }
        // `resultsIncomplete` is read AFTER `findAll`, which is what sets it:
        // it describes the list just returned, cache hit or fresh scan.
        findBar.setMatchCount(current: index, total: all.count,
                              limited: all.count >= SearchEngine.defaultLimit,
                              incomplete: search.resultsIncomplete)
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityValue() -> Any? {
        // What the user is LOOKING at: scrolled back, the live screen at the
        // bottom is not what VoiceOver should read. Screen readers ask line
        // by line, so this is memoised (a full build was O(rows²) once).
        let buffer = terminal.buffer
        if axValueChange != terminal.changeCounter || axValueRows != terminal.rows
            || axValueViewport != buffer.ydisp {
            var lines: [String] = []
            lines.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                let line = buffer.lineNumber(ofViewportRow: row)
                lines.append(buffer.row(line: line)?.string(trimRight: true) ?? "")
            }
            axValue = lines.joined(separator: "\n")
            axValueChange = terminal.changeCounter
            axValueRows = terminal.rows
            axValueViewport = buffer.ydisp
        }
        return axValue
    }
    private var axValue = ""
    private var axValueChange: UInt64 = .max
    private var axValueRows = 0
    private var axValueViewport = -1

    // MARK: - Preedit (IME)

    /// Show / move / hide the little floating box that carries the text the
    /// input method has not committed yet (Thai and Korean type through it).
    func updatePreedit() {
        if markedText.isEmpty {
            preedit?.removeFromSuperview()
            preedit = nil
            return
        }
        let field: NSTextField
        if let preedit {
            field = preedit
        } else {
            field = NSTextField(labelWithString: "")
            field.font = font
            field.drawsBackground = true
            field.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.001)
            field.isBordered = false
            addSubview(field)
            preedit = field
        }
        field.attributedStringValue = NSAttributedString(
            string: markedText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(srgbRed: CGFloat((colors.foreground >> 16) & 0xFF) / 255,
                                          green: CGFloat((colors.foreground >> 8) & 0xFF) / 255,
                                          blue: CGFloat(colors.foreground & 0xFF) / 255,
                                          alpha: 1),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        field.sizeToFit()
        positionPreedit()
    }

    private func positionPreedit() {
        guard let preedit else { return }
        let origin = cursorOrigin()
        preedit.frame.origin = CGPoint(x: origin.x, y: origin.y)
    }

    /// Top-left of the cursor cell, in view coordinates.
    func cursorOrigin() -> CGPoint {
        let b = terminal.buffer
        let row = b.ybase - b.ydisp + b.y
        return CGPoint(x: CGFloat(min(b.x, max(0, terminal.cols - 1))) * cellWidth,
                       y: CGFloat(row) * cellHeight)
    }

    // MARK: - Small helpers

    /// A cheap snapshot of everything about the selection a frame depends on.
    struct SelectionKey: Equatable {
        var active = false
        var mode: Selection.Mode = .character
        var start: Position?
        var end: Position?
        init() {}
        init(_ s: Selection) {
            active = s.isActive
            mode = s.mode
            start = s.start
            end = s.end
        }
    }

    /// Hold / release frames for mode 2026.
    func holdFrames(_ enabled: Bool) {
        syncHoldUntil = enabled ? CACurrentMediaTime() + TerminalView.synchronizedOutputHold : 0
        setNeedsFrame()
    }

    /// Forget the current search match (a buffer switch renumbers everything).
    func currentMatchCleared() {
        currentMatch = nil
    }

    /// The OSC 8 URI under a cell, if any.
    func link(at position: Position) -> String? {
        guard let row = terminal.buffer.row(line: position.line),
              position.col < row.cols else { return nil }
        // A wide glyph is one character in two cells, and the link lives on the
        // head: clicking its right half has to open the same URL, not nothing.
        var col = position.col
        if row[col].width == 0, col > 0, row[col - 1].width == 2 { col -= 1 }
        guard let ext = row.extended(at: col),
              ext.hyperlinkID > 0 else { return nil }
        let index = Int(ext.hyperlinkID) - 1
        guard index >= 0, index < terminal.hyperlinks.count else { return nil }
        return terminal.hyperlinks[index]
    }
}
