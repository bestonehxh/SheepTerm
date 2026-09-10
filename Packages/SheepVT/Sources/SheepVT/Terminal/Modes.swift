// SheepVT — the terminal's mode flags.
//
// One flat struct of Bools (plus the two mouse enums) instead of a bitfield:
// every site that reads a mode reads it by name, and the whole thing is a
// value type so saving/restoring or diffing it is a copy. Names follow the
// DEC mnemonics; the comment on each line is the sequence that toggles it.

public struct Modes: Sendable {

    // MARK: ANSI modes (CSI Pm h / CSI Pm l)

    /// IRM — `CSI 4 h`. Printing shifts the rest of the row right.
    public var insert = false
    /// LNM — `CSI 20 h`. LF/VT/FF also perform a carriage return.
    public var lineFeedNewline = false

    // MARK: DEC private modes (CSI ? Pm h / CSI ? Pm l)

    /// DECCKM — `CSI ? 1 h`. Cursor keys send SS3 instead of CSI.
    public var applicationCursorKeys = false
    /// DECOM — `CSI ? 6 h`. Cursor addressing is relative to the scroll region.
    public var originMode = false
    /// DECAWM — `CSI ? 7 h`. Printing past the last column wraps. Default on.
    public var autoWrap = true
    /// `CSI ? 45 h`. BS at column 0 may undo a soft wrap.
    public var reverseWrap = false
    /// DECTCEM — `CSI ? 25 h`. Default on.
    public var cursorVisible = true
    /// `CSI ? 12 h` (att610). Also set by the odd DECSCUSR styles.
    public var cursorBlink = false
    /// DECSCNM — `CSI ? 5 h`. The renderer swaps fg/bg for the whole screen.
    public var reverseVideo = false
    /// DECKPAM (`ESC =`) / DECKPNM (`ESC >`), also `CSI ? 66 h`.
    public var applicationKeypad = false
    /// `CSI ? 2004 h`. Pasted text is bracketed with `ESC [ 200 ~` … `ESC [ 201 ~`.
    public var bracketedPaste = false
    /// `CSI ? 1004 h`. Focus in/out is reported as `ESC [ I` / `ESC [ O`.
    public var focusEvents = false
    /// `CSI ? 1034 h` (eightBitInput). Meta sets the 8th bit instead of prefixing ESC.
    public var sendMeta8 = false
    /// `CSI ? 2026 h`. The renderer should hold paints while this is set.
    public var synchronizedOutput = false

    /// Read-only mirror of `Terminal.isAlternate` — kept here so a host that
    /// snapshots `modes` sees which screen it belongs to. Only the terminal
    /// writes it.
    public internal(set) var altScreen = false

    // MARK: mouse

    /// `CSI ? 9/1000/1002/1003 h`.
    public var mouseTracking: MouseTracking = .none
    /// `CSI ? 1005/1006/1015/1016 h`.
    public var mouseEncoding: MouseEncoding = .x10
    /// `CSI ? 1007 h`. The alternate screen turns wheel events into cursor keys.
    public var alternateScroll = false

    // MARK: columns

    /// DECCOLM — `CSI ? 3 h`. Recorded only: SheepVT never resizes itself
    /// (the host owns the window), so this sets nothing else.
    public var column132 = false
    /// DECNCSM's companion `CSI ? 40 h` — whether DECCOLM is allowed at all.
    public var allow80To132 = false

    public init() {}
}
