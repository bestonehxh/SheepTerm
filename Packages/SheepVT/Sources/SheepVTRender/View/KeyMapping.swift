// SheepVTRender — NSEvent → `KeyEvent`.
//
// The only place in the package that knows about AppKit's idea of a key. It is
// pure and `nonisolated`: hand it an event, get a value the core's `KeyEncoder`
// understands. Nothing here reads the terminal, the view or the current input
// source — the tables below are the event's own `keyCode` and the two strings
// AppKit already computed, so the same event always maps to the same key
// whatever keyboard layout is installed (which is also what makes it testable).
//
// The keyCode → functional-key and keyCode → US-layout tables are ported from
// SwiftTerm's `MacTerminalView.swift` (`kittyFunctionalKey(from:)`,
// `kittyModifierKey`, `kittyBaseLayoutKeyMap`), MIT.

import AppKit

public enum KeyMapping {

    // MARK: - Modifiers

    /// AppKit modifier flags → the core's `KeyModifiers`.
    ///
    /// `⌘` becomes `.super`, which every encoder refuses to encode: a ⌘ chord
    /// is the app's shortcut and must reach AppKit's menu handling untouched.
    /// macOS has no Num Lock, so `.numLock` is reported only for the keypad's
    /// own keys, where it is always effectively on.
    public nonisolated static func modifiers(from flags: NSEvent.ModifierFlags,
                                             keypad: Bool = false) -> KeyModifiers {
        var mods: KeyModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.command) { mods.insert(.super) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        if keypad { mods.insert(.numLock) }
        return mods
    }

    public nonisolated static func modifiers(from event: NSEvent) -> KeyModifiers {
        modifiers(from: event.modifierFlags, keypad: isKeypadCode(event.keyCode))
    }

    // MARK: - The event

    /// Turn an AppKit key event into a `KeyEvent`.
    ///
    /// `type` lets the caller build a release event out of `keyUp`, and
    /// `composing` marks the event as arriving while an IME/dead-key sequence
    /// is open (the kitty encoder drops everything but modifiers then).
    public nonisolated static func keyEvent(from event: NSEvent,
                                            type: KeyEventType = .press,
                                            composing: Bool = false) -> KeyEvent {
        let mods = modifiers(from: event)
        let typed = printableText(of: event)

        if let key = functionalKey(from: event) {
            // Only the keypad's typing half carries text — an arrow key's
            // `characters` is a private-use scalar, not something to send.
            let text = isKeypadTyping(key) ? typed : nil
            return KeyEvent(key: .functional(key),
                            modifiers: mods,
                            type: type,
                            text: text,
                            composing: composing)
        }

        let shift = mods.contains(.shift)
        let ignoring = event.charactersIgnoringModifiers ?? ""
        let lowered = ignoring.lowercased().unicodeScalars.first
        let us = usBaseLayoutKey[event.keyCode]
        // With shift down `charactersIgnoringModifiers` is already the *shifted*
        // character ("@" for ⇧2), so the unshifted identity of the key comes
        // from the layout table when there is one.
        let base: Unicode.Scalar? = shift ? (us ?? lowered) : (lowered ?? us)

        guard let base else {
            // A key AppKit could not name at all (some media keys): let the
            // encoder decide what to do with the text, if any.
            return KeyEvent(key: .none, modifiers: mods, type: type,
                            text: typed, composing: composing)
        }

        var shifted: UInt32?
        if shift {
            // `charactersIgnoringModifiers` is already the shifted character
            // (`_` for ⇧-); `characters` is nil for ⌃⇧ chords, which is exactly
            // when the shifted key matters (⌃_ , ⌃?).
            let produced = ignoring.unicodeScalars.first ?? typed?.unicodeScalars.first
            if let produced, produced.value != base.value { shifted = produced.value }
        }
        let baseLayout: UInt32? = (us != nil && us!.value != base.value) ? us!.value : nil

        return KeyEvent(key: .unicode(base.value),
                        modifiers: mods,
                        type: type,
                        text: typed,
                        shiftedKey: shifted,
                        baseLayoutKey: baseLayout,
                        composing: composing)
    }

    /// `event.characters` when it is text a program would want, else nil:
    /// control bytes, DEL and AppKit's private-use function-key scalars are not
    /// text, and a dead key produces an empty string (⌥e → "").
    public nonisolated static func printableText(of event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        for scalar in chars.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F { return nil }
            if (0xF700...0xF8FF).contains(v) { return nil }
        }
        return chars
    }

    // MARK: - Functional keys

    /// The key's identity when it is not a plain Unicode key. The `keyCode`
    /// table comes first because it is layout-independent; the private-use
    /// scalars AppKit puts in `charactersIgnoringModifiers` catch the handful
    /// of keys only some keyboards have (Insert, Print Screen, Pause, F21+).
    public nonisolated static func functionalKey(from event: NSEvent) -> FunctionalKey? {
        if let key = keyCodeMap[event.keyCode] { return key }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }
        return functionKeyMap[Int(scalar.value)]
    }

    /// The modifier key itself (`flagsChanged`), for kitty's report-all-keys.
    public nonisolated static func modifierKey(from keyCode: UInt16) -> FunctionalKey? {
        switch keyCode {
        case 54: return .rightSuper
        case 55: return .leftSuper
        case 56: return .leftShift
        case 57: return .capsLock
        case 58: return .leftAlt
        case 59: return .leftControl
        case 60: return .rightShift
        case 61: return .rightAlt
        case 62: return .rightControl
        default: return nil
        }
    }

    /// Keypad keys that type a character (so they carry `text`), as opposed to
    /// the keypad's navigation half.
    nonisolated static func isKeypadTyping(_ key: FunctionalKey) -> Bool {
        switch key {
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply,
             .keypadSubtract, .keypadAdd, .keypadEqual, .keypadSeparator:
            return true
        default:
            return false
        }
    }

    nonisolated static func isKeypadCode(_ code: UInt16) -> Bool {
        switch code {
        case 65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92:
            return true
        default:
            return false
        }
    }

    /// Virtual key code → functional key. Values are the `kVK_*` constants
    /// (Carbon `Events.h`), written out so the file needs no Carbon import.
    nonisolated static let keyCodeMap: [UInt16: FunctionalKey] = [
        36: .enter,          // Return
        48: .tab,
        51: .backspace,      // Delete (backwards)
        53: .escape,
        71: .keypadBegin,    // Clear
        76: .keypadEnter,    // Enter on the keypad
        114: .insert,        // Help
        115: .home,
        116: .pageUp,
        117: .delete,        // Forward delete
        119: .end,
        121: .pageDown,
        123: .left,
        124: .right,
        125: .down,
        126: .up,
        // Function keys, in F1…F20 order: 122 120 99 118 96 97 98 100 101 109
        // 103 111 105 107 113 106 64 79 80 90.
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5,
        97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10,
        103: .f11, 111: .f12, 105: .f13, 107: .f14, 113: .f15,
        106: .f16, 64: .f17, 79: .f18, 80: .f19, 90: .f20,
        // The keypad.
        82: .keypad0, 83: .keypad1, 84: .keypad2, 85: .keypad3, 86: .keypad4,
        87: .keypad5, 88: .keypad6, 89: .keypad7, 91: .keypad8, 92: .keypad9,
        65: .keypadDecimal, 67: .keypadMultiply, 69: .keypadAdd,
        75: .keypadDivide, 78: .keypadSubtract, 81: .keypadEqual,
    ]

    /// AppKit's private-use function-key scalars (`NSUpArrowFunctionKey` …),
    /// for keyboards whose keys do not appear in the `keyCode` table.
    nonisolated static let functionKeyMap: [Int: FunctionalKey] = [
        NSUpArrowFunctionKey: .up,
        NSDownArrowFunctionKey: .down,
        NSLeftArrowFunctionKey: .left,
        NSRightArrowFunctionKey: .right,
        NSHomeFunctionKey: .home,
        NSEndFunctionKey: .end,
        NSPageUpFunctionKey: .pageUp,
        NSPageDownFunctionKey: .pageDown,
        NSInsertFunctionKey: .insert,
        NSDeleteFunctionKey: .delete,
        NSPrintScreenFunctionKey: .printScreen,
        NSScrollLockFunctionKey: .scrollLock,
        NSPauseFunctionKey: .pause,
        NSMenuFunctionKey: .menu,
        NSF1FunctionKey: .f1, NSF2FunctionKey: .f2, NSF3FunctionKey: .f3,
        NSF4FunctionKey: .f4, NSF5FunctionKey: .f5, NSF6FunctionKey: .f6,
        NSF7FunctionKey: .f7, NSF8FunctionKey: .f8, NSF9FunctionKey: .f9,
        NSF10FunctionKey: .f10, NSF11FunctionKey: .f11, NSF12FunctionKey: .f12,
        NSF13FunctionKey: .f13, NSF14FunctionKey: .f14, NSF15FunctionKey: .f15,
        NSF16FunctionKey: .f16, NSF17FunctionKey: .f17, NSF18FunctionKey: .f18,
        NSF19FunctionKey: .f19, NSF20FunctionKey: .f20, NSF21FunctionKey: .f21,
        NSF22FunctionKey: .f22, NSF23FunctionKey: .f23, NSF24FunctionKey: .f24,
        NSF25FunctionKey: .f25, NSF26FunctionKey: .f26, NSF27FunctionKey: .f27,
        NSF28FunctionKey: .f28, NSF29FunctionKey: .f29, NSF30FunctionKey: .f30,
        NSF31FunctionKey: .f31, NSF32FunctionKey: .f32, NSF33FunctionKey: .f33,
        NSF34FunctionKey: .f34, NSF35FunctionKey: .f35,
    ]

    /// Virtual key code → the character that key carries on the US layout —
    /// kitty's `base_layout_key`. Ported from SwiftTerm (MIT).
    nonisolated static let usBaseLayoutKey: [UInt16: Unicode.Scalar] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 49: " ", 50: "`",
    ]
}
