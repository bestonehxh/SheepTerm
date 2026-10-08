// SheepVT — the state machine: bytes in, grid out.
//
// `Terminal` is the `VTActor` the parser drives. It owns the two buffers, the
// pen, the modes and the tiny amount of session state (title, palette,
// hyperlinks, kitty keyboard flags) and it is the only place that mutates the
// grid. Everything here runs on whatever queue calls `feed` — there are no
// locks and nothing is `Sendable`; one terminal belongs to one queue.
//
// Semantics follow xterm, read out of xterm.js `InputHandler.ts` (MIT) with
// vte `ansi.rs` as a second opinion. The dispatch tables live in the
// `Terminal+CSI/ESC/OSC/SGR` extensions; printing lives in `Terminal+Print`.

// -- Exclusivity enforcement on the hot stored properties --
//
// The grid classes skip dynamic exclusivity checking (the full argument is at
// the top of `Row.swift`); the same properties here are read and written several
// times per printed character — `Terminal.print` alone paid 58 begin/endAccess
// pairs, and after `Row`/`LineRing`/`Buffer` were annotated this file was all
// that was left, at 37% of a Unicode profile. `./Tests/run.sh vt-exclusivity`
// re-runs the whole suite with every annotation stripped and enforcement back
// on, which is how the claim below stays checkable rather than remembered.
//
// `Terminal` is the one class here where re-entrancy is a real question: the
// parser drives it and it calls out to a delegate that is the view, which does
// reach back in (the view's `bufferActivated` clears the selection and
// invalidates the search engine, both of which read the buffer). That is only
// an exclusivity problem if a property is *open* across the call out, which
// needs an `inout` argument or a `modify` coroutine yielded to user code.
// Neither exists: no stored property in SheepVT is ever passed `inout` (the only
// `&` arguments in the module are on locals — `Buffer+Reflow`'s row array and
// `VTParser`'s pending buffer), every delegate call is its own statement with
// its arguments already evaluated, and `pen`/`modes` are `Sendable` structs of
// trivial fields whose in-place mutation cannot call anything. The collection
// properties are only ever assigned whole or subscripted with an already
// computed value (`palette[i] = rgb`, `charsets[g] = Charsets.designation(…)`).
//
// Left CHECKED on purpose:
//   * `delegate` — a weak reference, and the one property read at the exact
//     moment control leaves the terminal. It is loaded once per callback, not
//     per character, so there is nothing to win and it is the last place worth
//     giving up a check.
//   * `title`, `iconName`, `cursorStyle`, `palette`, `host*`/`effective*`
//     colours, `defaultColorGeneration`, `hyperlinks`, `hyperlinkIndex`,
//     `hyperlinkBytes`, `kitty*`, `dcs*`, `scrollbackLines` — none is on the
//     per-character path, so annotating them would trade a check for nothing.
//   * `parser` is a `let`: never enforced in the first place.

public final class Terminal: VTActor {

    // MARK: - Host

    public weak var delegate: (any TerminalDelegate)?

    // MARK: - Geometry

    @exclusivity(unchecked) public private(set) var cols: Int
    @exclusivity(unchecked) public private(set) var rows: Int

    /// Scrollback capacity of the primary buffer (the alternate screen never
    /// has any). Setting it re-caps the ring, dropping the oldest lines.
    public var scrollback: Int {
        get { scrollbackLines }
        set {
            let n = Swift.max(0, newValue)
            guard n != scrollbackLines else { return }
            scrollbackLines = n
            primary.setScrollback(n)
            touch()
        }
    }
    private var scrollbackLines: Int

    // MARK: - Parser

    public let parser: VTParser

    // MARK: - Buffers

    @exclusivity(unchecked) public private(set) var primary: Buffer
    @exclusivity(unchecked) public private(set) var alternate: Buffer
    @exclusivity(unchecked) public private(set) var isAlternate = false
    public var buffer: Buffer { isAlternate ? alternate : primary }

    // MARK: - Attributes and modes

    @exclusivity(unchecked) public var pen = Pen()
    @exclusivity(unchecked) public var modes = Modes()

    public private(set) var title = ""
    public private(set) var iconName = ""
    public private(set) var cursorStyle: CursorStyle = .blinkBlock
    public var cursorVisible: Bool { modes.cursorVisible }

    /// OSC 4 palette overrides. `nil` = "use the theme's colour for this index".
    public private(set) var palette: [UInt32?] = Array(repeating: nil, count: 256)

    // MARK: - Default colours (OSC 10/11/12 and 110/111/112)
    //
    // Two parties move these, so each one is kept twice. The HOST (the app's
    // theme) owns `hostX`; a PROGRAM moves what is in effect with OSC 10/11/12
    // and is expected to hand it back with OSC 110/111/112 on the way out —
    // which it can only do if something still remembers what the theme asked
    // for. Before 3.0 (27) the host wrote straight into the effective colour,
    // so `htop` setting its own background and politely restoring it left the
    // user's theme gone until the app was restarted.

    /// SheepTerm's own theme, so a bare `Terminal` in a test or a headless
    /// session starts on the colours the app paints with.
    public static let themeForeground: UInt32 = 0xEDEFF3
    public static let themeBackground: UInt32 = 0x1E2128

    /// The theme's foreground. `OSC 110` and RIS come back to it.
    public private(set) var hostForeground: UInt32 = Terminal.themeForeground
    /// The theme's background. `OSC 111` and RIS come back to it.
    public private(set) var hostBackground: UInt32 = Terminal.themeBackground
    /// The theme's cursor colour. `OSC 112` and RIS come back to it.
    public private(set) var hostCursorColor: UInt32 = Terminal.themeForeground

    private var effectiveForeground: UInt32 = Terminal.themeForeground
    private var effectiveBackground: UInt32 = Terminal.themeBackground
    private var effectiveCursorColor: UInt32 = Terminal.themeForeground

    /// What is in effect: the theme's foreground, or the one a program set with
    /// `OSC 10`. This is what `OSC 10 ?` answers and what the renderer paints.
    ///
    /// **Assigning it is the host's move** — the user picked a theme — so it
    /// takes the colour as the new baseline *and* as what is in effect, and a
    /// program's override is dropped. The alternative (keep the override, move
    /// only the baseline) gives a half-changed picture: the host sets the ANSI
    /// palette, the selection and the cursor in the same breath
    /// (`TerminalView.colors`), so a new theme everywhere except the fg/bg a
    /// program happens to hold reads as a bug, and the theme picker looks dead
    /// while a full-screen program is up. Nothing is stranded either way: the
    /// program's `OSC 110/111` on the way out lands on the new baseline, which
    /// is the theme the user is now looking at.
    public var defaultForeground: UInt32 {
        get { effectiveForeground }
        set { hostForeground = newValue; moveForeground(to: newValue) }
    }

    /// What is in effect (`OSC 11`). Assigning it is the host's move — see
    /// `defaultForeground`.
    public var defaultBackground: UInt32 {
        get { effectiveBackground }
        set { hostBackground = newValue; moveBackground(to: newValue) }
    }

    /// What is in effect (`OSC 12`). Assigning it is the host's move — see
    /// `defaultForeground`. The theme draws the cursor in its text colour, so
    /// an unconfigured terminal starts with the foreground here.
    public var defaultCursorColor: UInt32 {
        get { effectiveCursorColor }
        set { hostCursorColor = newValue; moveCursorColor(to: newValue) }
    }

    /// Bumped every time a default colour actually moves. A renderer cannot
    /// tell "OSC 10/11 changed the colours" from "the host's theme owns them"
    /// by comparing the values — the host sets both sides and the comparison
    /// would overwrite the theme on every frame — so it follows this counter
    /// instead and syncs whenever it differs from the value it last applied.
    /// Every path that moves a colour goes through the three `move…` helpers,
    /// so the host's theme, a program's OSC 10/11/12, the OSC 110/111/112
    /// restores and RIS are all counted without anyone having to remember to.
    public private(set) var defaultColorGeneration: UInt64 = 0

    /// A program's `OSC 10/11/12`: move what is in effect and leave the host's
    /// baseline alone, so the matching reset has somewhere to come back to.
    func setProgramForeground(_ rgb: UInt32) { moveForeground(to: rgb) }
    func setProgramBackground(_ rgb: UInt32) { moveBackground(to: rgb) }
    func setProgramCursorColor(_ rgb: UInt32) { moveCursorColor(to: rgb) }

    /// `OSC 110/111/112` — and RIS, which restores all three at once.
    func restoreHostForeground() { moveForeground(to: hostForeground) }
    func restoreHostBackground() { moveBackground(to: hostBackground) }
    func restoreHostCursorColor() { moveCursorColor(to: hostCursorColor) }
    func restoreHostDefaultColors() {
        restoreHostForeground()
        restoreHostBackground()
        restoreHostCursorColor()
    }

    // Separate one-liners rather than one `inout` helper: passing `&self.x` to
    // a method on `self` is an overlapping access, and the whole point of this
    // file is that nothing here needs a lock to be safe.
    private func moveForeground(to rgb: UInt32) {
        guard effectiveForeground != rgb else { return }
        effectiveForeground = rgb
        defaultColorGeneration &+= 1
    }

    private func moveBackground(to rgb: UInt32) {
        guard effectiveBackground != rgb else { return }
        effectiveBackground = rgb
        defaultColorGeneration &+= 1
    }

    private func moveCursorColor(to rgb: UInt32) {
        guard effectiveCursorColor != rgb else { return }
        effectiveCursorColor = rgb
        defaultColorGeneration &+= 1
    }

    // MARK: - Change tracking

    /// Bumped whenever anything visible may have changed.
    @exclusivity(unchecked) public private(set) var changeCounter: UInt64 = 0
    /// Bumped when a visible (non-blank) character is printed. A renderer can
    /// tell "the device erased something and paused" (pager prompt going away)
    /// from "there is new text to show" and hold the frame for the former.
    @exclusivity(unchecked) public private(set) var visibleGlyphsPrinted: UInt64 = 0
    func noteVisibleGlyph() { visibleGlyphsPrinted &+= 1 }
    /// Screen rows touched since the last `clearDirty()`; nil = nothing.
    @exclusivity(unchecked) public private(set) var dirtyRows: ClosedRange<Int>?

    // MARK: - Line-number holders

    // Line numbers (`Buffer+Lines.swift`) are scroll-invariant *by
    // construction* — `trimmed + index`, where an ordinary scroll moves both
    // halves in opposite directions — so nothing normally has to be told when
    // the grid scrolls. The one exception is a top-anchored scroll region whose
    // bottom margin is above the last row (`Buffer.scrollUp`): the blank it
    // pushes into history has to be moved back down to the bottom of the
    // *region*, which renumbers every row below the margin without touching
    // their text.
    //
    // The three other holders of line numbers all self-heal, because
    // `LineRing.move` bumps the generation of every row whose index changed and
    // they each validate a cached entry against row identity + generation: the
    // renderer's row cache, `SearchEngine` (which also recomputes whenever
    // `changeCounter` moves) and `HighlightOverlay`. `Selection` is the one that
    // holds a raw number with nothing to check it against, so it gets told.
    //
    // The list is here, in the core, rather than on the view: a `Selection`
    // built straight from a `Terminal` (every test, and any headless host) has
    // no view to route the news through. Registration is `Selection.init`'s
    // job; the references are weak, so a dropped selection simply stops
    // answering and is compacted away on the next registration.

    private struct WeakSelection { weak var value: Selection? }
    private var lineNumberHolders: [WeakSelection] = []

    func registerLineNumberHolder(_ selection: Selection) {
        lineNumberHolders.removeAll { $0.value == nil || $0.value === selection }
        lineNumberHolders.append(WeakSelection(value: selection))
    }

    /// Line numbers `line` and above just moved by `delta`; their text did not.
    /// Called from `Buffer.scrollUp`, once per scrolled line, and only on the
    /// one path that renumbers — an ordinary full-screen scroll never gets here.
    func linesRenumbered(atOrAfter line: Int, by delta: Int) {
        guard delta != 0, !lineNumberHolders.isEmpty else { return }
        for holder in lineNumberHolders {
            holder.value?.shiftLines(atOrAfter: line, by: delta)
        }
    }

    // MARK: - Charsets (ISO 2022, G0…G3 + locking shift level)

    @exclusivity(unchecked) var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    @exclusivity(unchecked) var glevel = 0
    var activeCharset: Charset { charsets[glevel & 3] }

    // MARK: - Hyperlinks (OSC 8)

    /// `id - 1` → URI. Ids are what `ExtendedAttributes.hyperlinkID` stores.
    public private(set) var hyperlinks: [String] = []
    /// "id\u{1}uri" → id, so the same link repeated on every cell of a run
    /// (and on every redraw) registers once.
    var hyperlinkIndex: [String: UInt32] = [:]
    /// URI bytes retained in `hyperlinks`, against `maxHyperlinkBytes`.
    var hyperlinkBytes = 0

    // MARK: - Kitty keyboard protocol

    /// Flags in effect on the active screen (top of that screen's stack).
    public private(set) var kittyKeyboardFlags = 0
    static let kittyStackLimit = 32
    var kittyStackPrimary: [Int] = []
    var kittyStackAlternate: [Int] = []
    /// The inactive screen's flags, swapped in on a buffer switch.
    var kittyFlagsSaved = 0

    // MARK: - REP bookkeeping

    /// The last code point `print` wrote — REP (`CSI b`) repeats it, but only
    /// when nothing but printing happened in between.
    @exclusivity(unchecked) var lastPrintedCode: UInt32?
    @exclusivity(unchecked) var lastActionWasPrint = false

    // MARK: - Init

    public init(cols: Int, rows: Int, scrollback: Int = 10_000, delegate: (any TerminalDelegate)? = nil) {
        let c = Swift.max(Terminal.minCols, cols)
        let r = Swift.max(Terminal.minRows, rows)
        self.cols = c
        self.rows = r
        self.scrollbackLines = Swift.max(0, scrollback)
        self.delegate = delegate
        self.primary = Buffer(cols: c, rows: r, scrollback: Swift.max(0, scrollback))
        self.alternate = Buffer(cols: c, rows: r, scrollback: 0)
        // VTParser wants its actor at init; we cannot hand it `self` before
        // every stored property exists, so it starts on a throwaway actor and
        // is re-pointed on the very next line (`VTParser.actor` is a settable
        // unowned reference, and the placeholder is never touched again).
        let placeholder = NullActor()
        self.parser = VTParser(actor: placeholder)
        self.parser.actor = self
        primary.resetTabs()
        alternate.resetTabs()
        adoptBuffers()
    }

    /// Both buffers point back here so a renumbering scroll can reach the
    /// selections. Every place that replaces a buffer has to call this.
    private func adoptBuffers() {
        primary.owner = self
        alternate.owner = self
    }

    /// A terminal narrower than two columns cannot represent a wide character
    /// at all; every emulator refuses to go below this.
    public static let minCols = 2
    public static let minRows = 1

    private final class NullActor: VTActor {
        func print(_ codePoint: UInt32) {}
    }

    // MARK: - Feeding

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) { parser.feed(bytes) }
    public func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    public func feed(_ text: String) { parser.feed(text) }

    // MARK: - Dirty bookkeeping

    /// Bump `changeCounter` without marking any row (mode/title/pen changes).
    public func touch() { changeCounter &+= 1 }

    public func markDirty(_ row: Int) {
        touch()
        guard row >= 0, row < rows else { return }
        if let d = dirtyRows {
            if row < d.lowerBound { dirtyRows = row...d.upperBound }
            else if row > d.upperBound { dirtyRows = d.lowerBound...row }
        } else {
            dirtyRows = row...row
        }
    }

    public func markDirty(rows range: ClosedRange<Int>) {
        touch()
        let lo = Swift.max(0, Swift.min(range.lowerBound, rows - 1))
        let hi = Swift.max(0, Swift.min(range.upperBound, rows - 1))
        guard lo <= hi else { return }
        if let d = dirtyRows {
            dirtyRows = Swift.min(d.lowerBound, lo)...Swift.max(d.upperBound, hi)
        } else {
            dirtyRows = lo...hi
        }
    }

    public func markAllDirty() {
        touch()
        dirtyRows = 0...(rows - 1)
    }

    public func clearDirty() { dirtyRows = nil }

    // MARK: - Resize

    public func resize(cols newCols: Int, rows newRows: Int) {
        let c = Swift.max(Terminal.minCols, newCols)
        let r = Swift.max(Terminal.minRows, newRows)
        guard c != cols || r != rows else { return }
        // Default attributes, not the pen's: xterm.js pads a resize with
        // DEFAULT_ATTR_DATA. Padding with the pen painted a coloured band
        // down every new column when the window was widened while a program
        // had left a background colour set (BCE is for erases, not for
        // cells that never existed).
        let fill = Cell.empty
        primary.resize(cols: c, rows: r, fill: fill)
        alternate.resize(cols: c, rows: r, fill: fill)
        cols = c
        rows = r
        clampBuffer(primary)
        clampBuffer(alternate)
        markAllDirty()
    }

    /// Belt and braces after a resize: `Buffer.resize` already clamps, but the
    /// saved-cursor state is ours, and a stale margin would be load-bearing.
    private func clampBuffer(_ b: Buffer) {
        b.scrollTop = Swift.max(0, Swift.min(b.scrollTop, rows - 1))
        b.scrollBottom = Swift.max(b.scrollTop, Swift.min(b.scrollBottom, rows - 1))
        b.x = Swift.max(0, Swift.min(b.x, cols))
        b.y = Swift.max(0, Swift.min(b.y, rows - 1))
        if var saved = b.savedCursor {
            saved.x = Swift.max(0, Swift.min(saved.x, cols - 1))
            saved.y = Swift.max(0, Swift.min(saved.y, rows - 1))
            b.savedCursor = saved
        }
    }

    // MARK: - Reset

    /// RIS (`ESC c`): everything back to power-on state.
    public func reset() {
        primary = Buffer(cols: cols, rows: rows, scrollback: scrollbackLines)
        alternate = Buffer(cols: cols, rows: rows, scrollback: 0)
        primary.resetTabs()
        alternate.resetTabs()
        adoptBuffers()
        isAlternate = false
        pen = Pen()
        modes = Modes()
        charsets = [.ascii, .ascii, .ascii, .ascii]
        glevel = 0
        title = ""
        iconName = ""
        cursorStyle = .blinkBlock
        palette = Array(repeating: nil, count: 256)
        // xterm's RIS drops the OSC 4 palette *and* the OSC 10/11/12 defaults;
        // dropping only the palette left a program's background behind after
        // the very sequence a shell sends to clean up after a crashed one
        // (`tput reset`). The host's theme is the power-on state here.
        restoreHostDefaultColors()
        hyperlinks.removeAll()
        hyperlinkIndex.removeAll()
        hyperlinkBytes = 0
        kittyKeyboardFlags = 0
        kittyFlagsSaved = 0
        kittyStackPrimary.removeAll()
        kittyStackAlternate.removeAll()
        lastPrintedCode = nil
        lastActionWasPrint = false
        dcsActive = false
        dcsOverflowed = false
        dcsPayload.removeAll()
        parser.reset()
        markAllDirty()
        // Unconditionally, not only when the alternate was showing: both
        // buffers are new objects, so a selection or a match taken against the
        // old primary is meaningless. `Selection.validate()` does not catch it
        // — the same line numbers exist in the fresh buffer, so the selection
        // survives and points at unrelated text. The delegate call is the one
        // "your buffer is gone" signal the view has.
        delegate?.bufferActivated(self, alternate: false)
    }

    /// DECSTR (`CSI ! p`): the polite reset — screen contents survive.
    public func softReset() {
        modes.cursorVisible = true
        modes.originMode = false
        modes.autoWrap = true
        modes.insert = false
        modes.applicationKeypad = false
        modes.applicationCursorKeys = false
        // xterm.js resets the DEC private modes as a block; these three are
        // the ones a dead program leaves behind that hurt the next one.
        modes.bracketedPaste = false
        modes.reverseWrap = false
        modes.focusEvents = false
        let b = buffer
        b.scrollTop = 0
        b.scrollBottom = rows - 1
        b.savedCursor = nil
        pen = Pen()
        charsets = [.ascii, .ascii, .ascii, .ascii]
        glevel = 0
        lastActionWasPrint = false
        touch()
    }

    // MARK: - Text out

    /// The visible screen, one string per row.
    public func screenLines(trimRight: Bool = true) -> [String] {
        let b = buffer
        var out: [String] = []
        out.reserveCapacity(rows)
        for y in 0..<rows { out.append(b.allocatedRow(y)?.string(trimRight: trimRight) ?? "") }
        return out
    }

    /// Scrollback plus screen — for tests and log dumps.
    public func allLines(trimRight: Bool = true) -> [String] {
        let b = buffer
        let total = Swift.max(b.lines.count, b.ybase + rows)
        var out: [String] = []
        out.reserveCapacity(total)
        for i in 0..<total {
            out.append(b.lines.allocatedRow(at: i)?.string(trimRight: trimRight) ?? "")
        }
        return out
    }

    // MARK: - Viewport (user scrollback)

    public func scrollViewport(by lines: Int) {
        let b = buffer
        let next = Swift.max(0, Swift.min(b.ybase, b.ydisp + lines))
        guard next != b.ydisp else { return }
        b.ydisp = next
        markAllDirty()
    }

    public func scrollViewportToBottom() {
        let b = buffer
        guard b.ydisp != b.ybase else { return }
        b.ydisp = b.ybase
        markAllDirty()
    }

    // MARK: - Replies

    func send(_ bytes: [UInt8]) {
        guard let delegate else { return }
        delegate.send(self, bytes: bytes)
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func unhandled(_ description: String) {
        delegate?.unhandled(self, description: description)
    }

    // MARK: - Cursor primitives (shared by CSI/ESC)

    /// Clamp the cursor into the addressable area. `maxCol` is `cols` for the
    /// handful of commands that tolerate the pending-wrap column.
    func restrictCursor(maxCol: Int? = nil) {
        let b = buffer
        let mc = maxCol ?? (cols - 1)
        b.x = Swift.max(0, Swift.min(mc, b.x))
        if modes.originMode {
            b.y = Swift.max(b.scrollTop, Swift.min(b.scrollBottom, b.y))
        } else {
            b.y = Swift.max(0, Swift.min(rows - 1, b.y))
        }
    }

    /// Absolute positioning. Under DECOM the row is relative to `scrollTop`.
    func setCursor(_ x: Int, _ y: Int) {
        let b = buffer
        markDirty(b.y)
        b.x = x
        b.y = modes.originMode ? b.scrollTop + y : y
        restrictCursor()
        markDirty(b.y)
    }

    /// Relative movement. Unlike absolute positioning this never re-applies
    /// the origin offset — DECOM only bounds where the cursor may land.
    func moveCursor(_ dx: Int, _ dy: Int) {
        let b = buffer
        markDirty(b.y)
        restrictCursor()
        b.x = b.x + dx
        b.y = b.y + dy
        restrictCursor()
        markDirty(b.y)
    }

    // MARK: - Tab stops

    func nextTabStop() -> Int {
        let b = buffer
        var x = b.x
        repeat { x += 1 } while x < cols && !tabStop(b, x)
        return Swift.max(0, Swift.min(x, cols - 1))
    }

    func previousTabStop() -> Int {
        let b = buffer
        var x = Swift.min(b.x, cols)
        repeat { x -= 1 } while x > 0 && !tabStop(b, x)
        return Swift.max(0, Swift.min(x, cols - 1))
    }

    private func tabStop(_ b: Buffer, _ x: Int) -> Bool {
        x >= 0 && x < b.tabStops.count ? b.tabStops[x] : false
    }

    // MARK: - Vertical movement

    /// LF / VT / FF / IND. Scrolls at the bottom margin, and clears the
    /// pending-wrap column (an explicit line feed is not a soft wrap).
    func linefeed(clearWrapped: Bool = true) {
        let b = buffer
        markDirty(b.y)
        if b.y == b.scrollBottom {
            b.scrollUp(1, fill: pen.eraseCell, wrapped: false)
            delegate?.scrolled(self, lines: 1)
            markAllDirty()
        } else if b.y < rows - 1 {
            // xterm.js `lineFeed` leaves the destination row's `isWrapped`
            // alone — LF, IND, NEL and CUD must all agree, or copy/reflow
            // depend on which "move down" the device happened to use.
            b.y += 1
        }
        if b.x >= cols { b.x = cols - 1 }
        markDirty(b.y)
    }

    /// RI (`ESC M`). Scrolls down at the top margin.
    func reverseIndex() {
        let b = buffer
        markDirty(b.y)
        if b.y == b.scrollTop {
            b.scrollDown(1, fill: pen.eraseCell)
            delegate?.scrolled(self, lines: -1)
            markDirty(rows: b.scrollTop...b.scrollBottom)
        } else if b.y > 0 {
            b.y -= 1
        }
        markDirty(b.y)
    }

    // MARK: - Saved cursor (DECSC / DECRC / SCOSC / SCORC)

    func saveCursor() {
        let b = buffer
        b.savedCursor = SavedCursor(
            x: Swift.min(b.x, cols - 1),
            y: b.y,
            pen: pen,
            charset: packedCharsetState(),
            originMode: modes.originMode,
            pendingWrap: b.x >= cols
        )
    }

    func restoreCursor() {
        let b = buffer
        guard let saved = b.savedCursor else {
            // xterm restores to the home position with default attributes when
            // nothing was ever saved.
            pen = Pen()
            charsets = [.ascii, .ascii, .ascii, .ascii]
            glevel = 0
            setCursor(0, 0)
            return
        }
        markDirty(b.y)
        pen = saved.pen
        unpackCharsetState(saved.charset)
        modes.originMode = saved.originMode
        b.y = Swift.max(0, Swift.min(rows - 1, saved.y))
        // xterm clamps the restored column into the screen: a cursor saved in
        // the pending-wrap column comes back on the last column with the wrap
        // cancelled (fixture t0060-DECSC). `pendingWrap` is recorded anyway —
        // it is what the saved position *meant*, which reflow will want.
        b.x = Swift.max(0, Swift.min(cols - 1, saved.x))
        // …and into the margins when origin mode is on (xterm.js
        // `restoreCursor` ends in `_restrictCursor`): a cursor saved at
        // screen row 7 restored after `CSI 1;3 r` printed on row 7, outside
        // the region.
        if modes.originMode { restrictCursor() }
        markDirty(b.y)
    }

    /// `SavedCursor.charset` is a single Int, so the whole ISO-2022 state is
    /// packed into it: bits 0–1 the locking-shift level, bits 2–3/4–5/6–7/8–9
    /// the charset designated into G0…G3.
    func packedCharsetState() -> Int {
        var v = glevel & 3
        for g in 0..<4 { v |= Int(charsets[g].rawValue & 3) << (2 + g * 2) }
        return v
    }

    func unpackCharsetState(_ v: Int) {
        glevel = v & 3
        for g in 0..<4 {
            let raw = UInt8((v >> (2 + g * 2)) & 3)
            charsets[g] = Charset(rawValue: raw) ?? .ascii
        }
    }

    // MARK: - Screen switching

    func activateAlternate(clearFirst: Bool) {
        guard !isAlternate else { return }
        swapKittyFlags()
        let fill = pen.eraseCell
        if clearFirst {
            for y in 0..<rows {
                let row = alternate.row(y)
                row.fill(fill)
                row.wrapped = false
            }
        }
        alternate.x = Swift.min(primary.x, cols)
        alternate.y = Swift.max(0, Swift.min(rows - 1, primary.y))
        alternate.ybase = 0
        alternate.ydisp = 0
        isAlternate = true
        modes.altScreen = true
        markAllDirty()
        delegate?.bufferActivated(self, alternate: true)
    }

    func activateNormal(clearAlternate: Bool) {
        guard isAlternate else { return }
        swapKittyFlags()
        primary.x = Swift.min(alternate.x, cols)
        primary.y = Swift.max(0, Swift.min(rows - 1, alternate.y))
        isAlternate = false
        modes.altScreen = false
        if clearAlternate {
            let fill = Cell.empty
            for y in 0..<rows {
                let row = alternate.row(y)
                row.fill(fill)
                row.wrapped = false
            }
        }
        primary.ydisp = primary.ybase
        markAllDirty()
        delegate?.bufferActivated(self, alternate: false)
    }

    /// Each screen has its own kitty flags; a buffer switch exchanges the
    /// active set with the one parked for the other screen.
    private func swapKittyFlags() {
        let current = kittyKeyboardFlags
        kittyKeyboardFlags = kittyFlagsSaved
        kittyFlagsSaved = current
    }

    // MARK: - Hyperlinks

    /// Register an OSC 8 link, deduplicating on id + URI. Returns the id that
    /// goes into `ExtendedAttributes.hyperlinkID` (0 = no link).
    func registerHyperlink(id: String, uri: String) -> UInt32 {
        guard !uri.isEmpty, uri.utf8.count <= Terminal.maxHyperlinkLength else { return 0 }
        // The id is retained too (it is half of the dedup key), so it is
        // bounded and counted: a device sending a long, never-repeating id
        // with a short URI could otherwise grow the table without ever
        // moving a counter that only watched URI bytes.
        guard id.utf8.count <= Terminal.maxHyperlinkIDLength else { return 0 }
        let key = id + "\u{1}" + uri
        if let existing = hyperlinkIndex[key] { return existing }
        let cost = key.utf8.count + uri.utf8.count
        guard hyperlinks.count < Terminal.maxHyperlinks,
              hyperlinkBytes + cost <= Terminal.maxHyperlinkBytes else { return 0 }
        hyperlinks.append(uri)
        hyperlinkBytes += cost
        let newID = UInt32(hyperlinks.count)
        hyperlinkIndex[key] = newID
        return newID
    }

    static let maxHyperlinks = 65_535
    /// Total URI bytes the table will ever retain. A device that emits a fresh
    /// link on every cell of every redraw would otherwise grow it forever.
    public static let maxHyperlinkBytes = 4 * 1024 * 1024
    /// A single URI longer than this is dropped (the text it wrapped stays).
    public static let maxHyperlinkLength = 8192
    /// An OSC 8 `id=` longer than this is dropped: it is retained in the
    /// dedup table, so it counts against the same budget the URIs do.
    public static let maxHyperlinkIDLength = 512

    // MARK: - Palette

    func setPaletteEntry(_ index: Int, _ rgb: UInt32?) {
        guard index >= 0, index < palette.count else { return }
        palette[index] = rgb
        touch()
    }

    func resetPalette() {
        palette = Array(repeating: nil, count: 256)
        touch()
    }

    func setTitle(_ s: String) {
        title = s
        touch()
        delegate?.titleChanged(self, title: s)
    }

    func setIconName(_ s: String) {
        iconName = s
        touch()
        delegate?.iconNameChanged(self, name: s)
    }

    func setCursorStyle(_ style: CursorStyle) {
        cursorStyle = style
        touch()
        delegate?.cursorStyleChanged(self, style: style)
    }

    func setKittyFlags(_ flags: Int) {
        kittyKeyboardFlags = flags & 0x1F
        touch()
    }

    var kittyStack: [Int] {
        get { isAlternate ? kittyStackAlternate : kittyStackPrimary }
        set { if isAlternate { kittyStackAlternate = newValue } else { kittyStackPrimary = newValue } }
    }

    // MARK: - VTActor: C0 controls

    public func execute(_ control: UInt8) {
        lastActionWasPrint = false
        switch control {
        case 0x07: // BEL
            delegate?.bell(self)
        case 0x08: // BS
            backspace()
        case 0x09: // HT
            let b = buffer
            guard b.x < cols else { break }
            b.x = nextTabStop()
            markDirty(b.y)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            if modes.lineFeedNewline { buffer.x = 0 }
            linefeed()
        case 0x0D: // CR
            buffer.x = 0
            markDirty(buffer.y)
        case 0x0E: // SO — locking shift to G1
            glevel = 1
            touch()
        case 0x0F: // SI — locking shift to G0
            glevel = 0
            touch()
        default:
            break // NUL, ENQ, CAN, SUB, … : nothing to do
        }
    }

    /// BS, including the `CSI ? 45 h` reverse-wrap extension: at column 0 a
    /// soft-wrapped row can be un-wrapped back to the end of the row above.
    /// Deliberately the xterm.js flavour — only soft NLs, only inside the
    /// margins, never into the scrollback.
    private func backspace() {
        let b = buffer
        guard modes.reverseWrap else {
            restrictCursor()
            if b.x > 0 { b.x -= 1 }
            markDirty(b.y)
            return
        }
        let from = b.y
        restrictCursor(maxCol: cols)
        if b.x > 0 {
            b.x -= 1
        } else if b.y > b.scrollTop, b.y <= b.scrollBottom, b.row(b.y).wrapped {
            let row = b.row(b.y)
            row.wrapped = false
            b.y -= 1
            b.x = cols - 1
            let above = b.row(b.y)
            let cell = above[b.x]
            // A cell that has width but no content is the hole left by a wide
            // char that wrapped early; step one further back.
            if !cell.isSpacer, cell.isEmpty, b.x > 0 { b.x -= 1 }
        }
        restrictCursor()
        markDirty(from)
        markDirty(b.y)
    }

    // MARK: - VTActor: DCS / APC

    public func dcsHook(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {
        lastActionWasPrint = false
        dcsActive = false
        // DCS $ q Pt ST — DECRQSS. We collect the payload and answer in unhook.
        if prefix == 0, intermediates.count == 1, intermediates.first == UInt8(ascii: "$"), final == UInt8(ascii: "q") {
            dcsActive = true
            dcsPayload.removeAll(keepingCapacity: true)
        } else {
            unhandled("DCS \(Character(UnicodeScalar(final)))")
        }
    }

    public func dcsPut(_ bytes: ArraySlice<UInt8>) {
        guard dcsActive, !dcsOverflowed else { return }
        guard dcsPayload.count + bytes.count <= Terminal.maxDCSPayload else {
            // Over the cap: abandon the whole string (SPEC: dropped, never
            // truncated) instead of splicing later chunks onto a hole.
            dcsOverflowed = true
            dcsPayload.removeAll(keepingCapacity: true)
            return
        }
        dcsPayload.append(contentsOf: bytes)
    }

    public func dcsUnhook() {
        guard dcsActive else { return }
        if dcsOverflowed { dcsActive = false; dcsOverflowed = false; return }
        dcsActive = false
        answerDECRQSS(String(decoding: dcsPayload, as: UTF8.self))
        dcsPayload.removeAll(keepingCapacity: true)
    }

    public func apcDispatch(_ payload: ArraySlice<UInt8>) {
        lastActionWasPrint = false
        unhandled("APC (\(payload.count) bytes)")
    }

    static let maxDCSPayload = 4096
    var dcsActive = false
    var dcsOverflowed = false
    var dcsPayload: [UInt8] = []

    /// DECRQSS — report the handful of settings a program might ask about.
    private func answerDECRQSS(_ request: String) {
        let b = buffer
        let body: String?
        switch request {
        case "m": body = "0m"                                  // SGR (xterm.js reports 0m too)
        case "r": body = "\(b.scrollTop + 1);\(b.scrollBottom + 1)r"
        case " q": body = "\(cursorStyle.rawValue) q"
        case "\"q": body = "\(pen.bg & Cell.BgFlag.protected != 0 ? 1 : 0)\"q"
        case "\"p": body = "61;1\"p"
        default: body = nil
        }
        if let body {
            send("\u{1b}P1$r\(body)\u{1b}\\")
        } else {
            send("\u{1b}P0$r\u{1b}\\")
        }
    }
}
