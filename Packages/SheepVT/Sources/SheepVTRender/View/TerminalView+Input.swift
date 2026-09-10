// SheepVTRender — keys and text input.
//
// The path is short on purpose: NSEvent → `KeyMapping.keyEvent` → the core's
// `KeyEncoder` → bytes. AppKit's own `interpretKeyEvents` is the **fallback**,
// not the main road: it is what makes dead keys and the IME work, and it is
// where anything the encoder declines (⌘ chords, keys with no sequence) goes.
//
// SwiftTerm does it the other way round — everything through
// `interpretKeyEvents` and `doCommand(by:)` — which is why its key handling is
// spread over three tables. Encoding first keeps every rule in the core, where
// it is tested headless.

import AppKit

/// What the input context did with a key we offered it (see
/// `offerToInputMethod`). Only the view that started the offer records into it,
/// so a stray callback from another view can never be mistaken for an answer.
private final class InputMethodOffer {
    let view: TerminalView
    /// Text committed through `insertText` while the offer was open.
    var committed: [String] = []
    /// A preedit appeared at any point during the offer — proof the key went
    /// into a composition even if the same key also committed the previous one.
    var opened = false

    init(view: TerminalView) { self.view = view }
}

/// The offer in flight. `NSTextInputContext.handleEvent` answers by calling
/// straight back into `NSTextInputClient` on this thread, so one main-actor
/// slot is all the bookkeeping a key needs; `offerToInputMethod` still saves
/// and restores it rather than assuming it is the only key in the world.
private var inputMethodOffer: InputMethodOffer?

extension TerminalView {

    // MARK: - Keys

    public override func keyDown(with event: NSEvent) {
        // While the input method is composing, everything belongs to it.
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        var keyEvent = KeyMapping.keyEvent(from: event)
        if event.isARepeat { keyEvent.type = .repeatPress }

        // ⌘ chords are the app's shortcuts. The encoder returns nil for them
        // (`.super`), and `super.keyDown` lets AppKit finish the job — never
        // swallow ⌘C.
        if keyEvent.modifiers.contains(.super) {
            super.keyDown(with: event)
            return
        }

        // Option-as-text: with `altSendsEscape` off a dead key (⌥e) produces no
        // text at all, and there is nothing to send until the OS composes one.
        if !altSendsEscape, keyEvent.modifiers.contains(.alt), keyEvent.text == nil {
            interpretKeyEvents([event])
            return
        }
        // A CJK/Pinyin input method composes from ordinary letter keys: give
        // the input context first refusal on plain Unicode keys (no ⌃/⌥
        // chords), so marked text can form. A plain layout (Thai, US) hands
        // the same letter straight back, and `offerToInputMethod` says so.
        //
        // The kitty flags do NOT gate this. The protocol has no opinion on how
        // the platform turns keystrokes into text: its own text-as-code-points
        // section describes the OS eating a key to produce text and handing the
        // terminal "only a text input event", and says the exact behaviour
        // "depends on the OS, keyboard layout, IME system in use" — a
        // composition is that case. Gating the input context on the flags cost
        // a Japanese/Korean/Chinese user their language inside every program
        // that turns the protocol on, disambiguation flag included.
        if case .unicode = keyEvent.key,
           !keyEvent.modifiers.contains(.ctrl),
           !(keyEvent.modifiers.contains(.alt) && altSendsEscape),
           let context = inputContext,
           offerToInputMethod(event, to: context, typed: keyEvent.text) {
            return
        }

        if let bytes = keyEncoder().encode(keyEvent) {
            send(bytes)
            scrollToBottom()
            return
        }

        // Dead keys, the IME, and anything the encoder had no sequence for.
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        let flags = KittyKeyboardFlags(rawValue: terminal.kittyKeyboardFlags)
        guard flags.contains(.reportEvents), !hasMarkedText() else {
            super.keyUp(with: event)
            return
        }
        let keyEvent = KeyMapping.keyEvent(from: event, type: .release)
        if let bytes = keyEncoder().encode(keyEvent) {
            send(bytes)
            return
        }
        super.keyUp(with: event)
    }

    /// Bare modifier keys — only the kitty protocol's report-all-keys mode
    /// wants them, and only it can express them.
    public override func flagsChanged(with event: NSEvent) {
        let flags = KittyKeyboardFlags(rawValue: terminal.kittyKeyboardFlags)
        guard flags.contains(.reportAllKeys),
              let key = KeyMapping.modifierKey(from: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        let down = isModifierDown(key, flags: event.modifierFlags)
        let keyEvent = KeyEvent(key: .functional(key),
                                modifiers: KeyMapping.modifiers(from: event),
                                type: down ? .press : .release)
        if let bytes = keyEncoder().encode(keyEvent) { send(bytes) }
    }

    private func isModifierDown(_ key: FunctionalKey, flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .leftShift, .rightShift: return flags.contains(.shift)
        case .leftControl, .rightControl: return flags.contains(.control)
        case .leftAlt, .rightAlt: return flags.contains(.option)
        case .leftSuper, .rightSuper: return flags.contains(.command)
        case .capsLock: return flags.contains(.capsLock)
        default: return false
        }
    }

    /// A `KeyEncoder` snapshotting the terminal plus the view's own two
    /// preferences.
    func keyEncoder() -> KeyEncoder {
        var encoder = KeyEncoder(terminal: terminal)
        encoder.altSendsEscape = altSendsEscape
        encoder.backspaceSendsControlH = backspaceSendsControlH
        return encoder
    }

    /// Offer a key to the input method and answer whether it took it.
    ///
    /// The input context replies by calling back into `NSTextInputClient`, so
    /// the callbacks are *captured* for the length of the call instead of
    /// acting at once. That is what tells a composition apart from an echo: a
    /// plain keyboard layout answers `a` by handing `a` straight back through
    /// `insertText`, and if that echo became the terminal's bytes the encoder
    /// would never run — under the kitty protocol the very same key has to
    /// leave as `CSI 97 u`, which only the encoder knows how to build. Marked
    /// text, or text that is not what the key itself types (Pinyin turning `,`
    /// into `，`), is the input method's own work: text with no key behind it,
    /// which is the protocol's pure "text input" event. `KeyEncoder.textInput`
    /// owns how that leaves — plain UTF-8, or `CSI 0 ; ; codepoints u` for a
    /// program that asked for text as code points.
    ///
    /// - Returns: true when the input method owns the key and the encoder must
    ///   not see it.
    func offerToInputMethod(_ event: NSEvent,
                            to context: NSTextInputContext,
                            typed: String?) -> Bool {
        let offer = InputMethodOffer(view: self)
        let outer = inputMethodOffer
        inputMethodOffer = offer
        let handled = context.handleEvent(event)
        inputMethodOffer = outer

        let composing = offer.opened || hasMarkedText()
        if offer.committed.isEmpty, !composing {
            // Nothing came back. Either the input method declined the key, or
            // it swallowed it whole (candidate-window navigation, or an
            // out-of-process method that will commit later — in which case
            // `insertText` will arrive with no offer open and send the text
            // itself). `handled` is all that tells the two apart, and encoding
            // a key the input method has already taken would double it.
            return handled
        }
        if !composing, offer.committed.allSatisfy({ $0 == typed }) {
            // The echo of the key we just offered: the encoder still owns it.
            return false
        }
        for text in offer.committed { send(keyEncoder().textInput(text)) }
        if !offer.committed.isEmpty { scrollToBottom() }
        return true
    }

    /// AppKit's interpretation of a key we handed back to it. Only the handful
    /// of editing selectors that map onto a terminal key are honoured; the rest
    /// are dropped silently (a terminal has no "move to end of paragraph").
    public override func doCommand(by selector: Selector) {
        let key: FunctionalKey?
        var extra: KeyModifiers = []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): key = .enter
        case #selector(NSResponder.insertLineBreak(_:)): key = .enter
        case #selector(NSResponder.insertTab(_:)): key = .tab
        case #selector(NSResponder.insertBacktab(_:)): key = .tab; extra = .shift
        case #selector(NSResponder.deleteBackward(_:)): key = .backspace
        case #selector(NSResponder.deleteForward(_:)): key = .delete
        case #selector(NSResponder.cancelOperation(_:)): key = .escape
        case #selector(NSResponder.moveUp(_:)): key = .up
        case #selector(NSResponder.moveDown(_:)): key = .down
        case #selector(NSResponder.moveLeft(_:)): key = .left
        case #selector(NSResponder.moveRight(_:)): key = .right
        case #selector(NSResponder.moveToBeginningOfLine(_:)): key = .home
        case #selector(NSResponder.moveToEndOfLine(_:)): key = .end
        case #selector(NSResponder.pageUp(_:)): key = .pageUp
        case #selector(NSResponder.pageDown(_:)): key = .pageDown
        default: key = nil
        }
        guard let key else { return }
        // A preedit is still on screen, so this is a key the input method
        // looked at and did not want (it commits with `insertText`, which
        // clears the preedit first). Nothing may reach the program underneath
        // a half-typed word — which is exactly what `KeyEvent.composing` means
        // to both encoders.
        let event = KeyEvent(key: .functional(key), modifiers: extra,
                             composing: hasMarkedText())
        if let bytes = keyEncoder().encode(event) {
            send(bytes)
            scrollToBottom()
        }
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
        }
        clearMarkedText()
        guard !text.isEmpty else { return }
        // Committed while `keyDown` is asking the input method about a key:
        // let it decide whether this is the input method's own text or only
        // the echo of a key the encoder still has to encode.
        if let offer = inputMethodOffer, offer.view === self {
            offer.committed.append(text)
            return
        }
        // No offer open: an out-of-process input method committing on its own
        // clock. Same text, same encoding as the offered route.
        send(keyEncoder().textInput(text))
        scrollToBottom()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as String: markedText = s
        case let s as NSAttributedString: markedText = s.string
        default: markedText = ""
        }
        // A preedit that appears during an offer is the proof that the key
        // opened a composition, and it outlives the commit that may follow in
        // the same key (`にほん` committed, `k` starting the next word).
        if !markedText.isEmpty, let offer = inputMethodOffer, offer.view === self {
            offer.opened = true
        }
        markedSelectedRange = selectedRange
        updatePreedit()
        setNeedsFrame()
    }

    public func unmarkText() {
        clearMarkedText()
    }

    func clearMarkedText() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        markedSelectedRange = NSRange(location: 0, length: 0)
        updatePreedit()
        setNeedsFrame()
    }

    public func selectedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : markedSelectedRange
    }

    public func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the candidate window goes: the cursor cell, in screen coordinates.
    public func firstRect(forCharacterRange range: NSRange,
                          actualRange: NSRangePointer?) -> NSRect {
        let origin = cursorOrigin()
        let rect = NSRect(x: origin.x, y: origin.y, width: cellWidth, height: cellHeight)
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
