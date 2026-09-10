// SheepVT — key events to bytes.
//
// Two encodings live here behind one `encode`:
//
//   * **legacy xterm** (the default, `kittyFlags` empty) — the ctlseqs rules:
//     `CSI`/`SS3` cursor keys, `CSI n ~` editing keys, `SS3` F1–F4, the control
//     byte a Ctrl chord produces, ESC-prefixed Alt, the application keypad.
//   * **kitty keyboard protocol** — turned on by the program with `CSI > flags u`
//     (`Terminal.kittyKeyboardFlags`). Ported from SwiftTerm's
//     `KittyKeyboardEncoder.swift` (MIT); it keeps kitty's own fallback to the
//     legacy sequences for the keys the protocol leaves untouched.
//
// The encoder is a `Sendable` value type: the view snapshots the terminal's
// modes once (`init(terminal:)`) and can then encode off the terminal's queue.
//
// `encode` returns nil when the key is **not the terminal's to handle** — a
// release event nobody asked for, a bare modifier, a ⌘ chord, a key the legacy
// encoding has no sequence for. The view then lets AppKit have it.

public struct KeyEncoder: Sendable {

    /// Flags the program set with `CSI > flags u`. Empty = legacy xterm.
    public var kittyFlags: KittyKeyboardFlags = []
    /// DECCKM: cursor keys send `SS3 A` instead of `CSI A`.
    public var applicationCursorKeys = false
    /// DECKPAM: the keypad sends `SS3 p`…`SS3 y` instead of digits.
    public var applicationKeypad = false
    /// Backspace sends 0x08 instead of DEL.
    public var backspaceSendsControlH = false
    /// Option/Alt prefixes ESC (false = let the OS text through, e.g. typing
    /// `é` with ⌥e).
    public var altSendsEscape = true
    /// DECSET 1034: Alt sets the 8th bit instead of prefixing ESC.
    public var metaSendsEightBit = false
    /// LNM (`CSI 20 h`): Return sends CR LF.
    public var lineFeedNewline = false

    public init() {}

    /// Snapshot of `terminal.modes` + `terminal.kittyKeyboardFlags`.
    public init(terminal: Terminal) {
        kittyFlags = KittyKeyboardFlags(rawValue: terminal.kittyKeyboardFlags)
            .intersection(.known)
        applicationCursorKeys = terminal.modes.applicationCursorKeys
        applicationKeypad = terminal.modes.applicationKeypad
        metaSendsEightBit = terminal.modes.sendMeta8
        lineFeedNewline = terminal.modes.lineFeedNewline
    }

    /// Bytes to write, or nil when the key is not the terminal's to handle.
    public func encode(_ event: KeyEvent) -> [UInt8]? {
        if kittyFlags.isEmpty {
            return encodeLegacy(event)
        }
        return encodeKitty(event)
    }

    // MARK: - Text input, paste and focus

    /// Text the OS produced with **no key event behind it** — an input method
    /// committing a candidate (`にほん` → `日本`), which is what the protocol
    /// calls a pure "text input" event.
    ///
    /// The kitty spec's *Text as code points* section is written for exactly
    /// this case: the OS "gets only a 'text input' event and no information
    /// about modifiers, thus the event gets encoded with no modifiers … if the
    /// terminal emulator receives no key information, the key number ``0`` must
    /// be used to indicate a pure 'text event'", its own example being
    /// `CSI 0 ; ; 229 u`. Multiple code points "must be separated by colons",
    /// which `encodeCsiU` already does for the with-a-key case.
    ///
    /// The gate is *Report associated text* (`0b10000`), which the spec calls
    /// "an enhancement to report_all_keys … undefined if used without it" — so
    /// both bits, the same pair `encodeKitty` requires before it embeds text in
    /// a key's own `CSI u`. In every other flag state, legacy included, the
    /// commit leaves as raw UTF-8, which is what the note above that section
    /// asks for: text-producing events "are reported as plain UTF-8 text".
    public func textInput(_ text: String) -> [UInt8] {
        guard kittyFlags.contains(.reportAllKeys),
              kittyFlags.contains(.reportText),
              // "The associated text must not contain control codes"; a commit
              // left with nothing after that filter has no `CSI u` form at all,
              // so it goes out as UTF-8 rather than being silently dropped.
              let codepoints = Self.textCodepoints(from: text),
              !codepoints.isEmpty else {
            return Array(text.utf8)
        }
        // Key code 0 and no modifiers field: the OS handed us neither. There is
        // no event type either — a text event is not a press/repeat/release.
        return encodeCsiU(event: KeyEvent(key: .none, text: text),
                          overrideKeyCode: 0,
                          includeText: true,
                          includeAlternates: false,
                          includeEventType: false,
                          includeLocks: false)
    }

    /// Newlines become CR (a terminal line ends with CR, and a pasted LF would
    /// look like a keypress the shell echoes twice). When `bracketed`, the text
    /// is wrapped in `ESC [ 200 ~` … `ESC [ 201 ~` — and any embedded copy of
    /// the end marker is removed so pasted text cannot escape its own brackets.
    ///
    /// A paste is **not** a text input event: the kitty keyboard protocol is
    /// scoped to key events end to end (its whole document never mentions
    /// paste), and its text-as-code-points rule that "the associated text must
    /// not contain control codes" cannot even express the CR a multi-line paste
    /// is made of. So the kitty flags do not reach this function — bracketed
    /// paste stays the only framing a paste gets, in every flag state.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        var body: [UInt8] = []
        body.reserveCapacity(text.utf8.count)
        var lastWasCR = false
        for b in text.utf8 {
            switch b {
            case C0.cr:
                body.append(C0.cr)
                lastWasCR = true
            case C0.lf:
                if !lastWasCR { body.append(C0.cr) }
                lastWasCR = false
            default:
                body.append(b)
                lastWasCR = false
            }
        }
        guard bracketed else { return body }
        let end: [UInt8] = [C0.esc, C0.leftBracket] + Array("201~".utf8)
        Self.removeAll(end, from: &body)
        let start: [UInt8] = [C0.esc, C0.leftBracket] + Array("200~".utf8)
        return start + body + end
    }

    /// Delete every copy of `marker` in one pass, output-stack style: keep each
    /// byte, and whenever the kept tail *is* the marker drop those bytes again.
    /// That is what handles the splice removing one copy can produce
    /// (`ESC[20` + `ESC[201~` + `1~`), which the old code paid for by rescanning
    /// the whole buffer until it stopped shrinking — quadratic on a clipboard
    /// crafted to nest, and this runs on the main actor. The answer is the same
    /// one: no proper prefix of `ESC [ 201 ~` is also a suffix of it, so two
    /// copies can never overlap and the order they are deleted in cannot change
    /// what is left.
    private static func removeAll(_ marker: [UInt8], from body: inout [UInt8]) {
        let m = marker.count
        guard m > 0, body.count >= m else { return }
        let terminator = marker[m - 1]
        var kept = 0
        for i in 0 ..< body.count {
            let b = body[i]
            body[kept] = b
            kept += 1
            // Only a byte that could END a copy is worth comparing, so an
            // ordinary paste pays one test per byte and nothing else.
            guard b == terminator, kept >= m else { continue }
            var k = 0
            while k < m, body[kept - m + k] == marker[k] { k += 1 }
            if k == m { kept -= m }
        }
        body.removeLast(body.count - kept)
    }

    /// `CSI I` / `CSI O` — sent only while the program asked for focus events.
    public static func focus(_ gained: Bool) -> [UInt8] {
        [C0.esc, C0.leftBracket, gained ? UInt8(ascii: "I") : UInt8(ascii: "O")]
    }

    // MARK: - Builders

    private func csi(_ payload: String) -> [UInt8] {
        var bytes: [UInt8] = [C0.esc, C0.leftBracket]
        bytes.append(contentsOf: payload.utf8)
        return bytes
    }

    private func ss3(_ payload: String) -> [UInt8] {
        var bytes: [UInt8] = [C0.esc, C0.bigO]
        bytes.append(contentsOf: payload.utf8)
        return bytes
    }
}

// MARK: - Legacy xterm encoding

extension KeyEncoder {

    /// The xterm modifier parameter minus one: shift 1, alt 2, ctrl 4, meta 8.
    /// Only an explicit `.meta` reaches bit 8 — ⌘ (`.super`) and Hyper chords
    /// are the app's shortcuts and never encode (the locks never take part).
    static func legacyModifier(_ modifiers: KeyModifiers) -> Int {
        var v = 0
        if modifiers.contains(.shift) { v |= 1 }
        if modifiers.contains(.alt) { v |= 2 }
        if modifiers.contains(.ctrl) { v |= 4 }
        if modifiers.contains(.meta) { v |= 8 }
        return v
    }

    private func encodeLegacy(_ event: KeyEvent) -> [UInt8]? {
        if event.type == .release { return nil }
        if event.composing { return nil }
        switch event.key {
        case .functional(let key):
            return encodeLegacyFunctional(key, event)
        case .unicode:
            return legacyTextKeySequence(event: event)
        case .none:
            guard let text = event.text, !text.isEmpty else { return nil }
            var mods = event.modifiers
            mods.remove(.locks)
            if !mods.isDisjoint(with: [.super, .hyper, .meta]) { return nil }
            return applyAlt(Array(text.utf8), modifiers: mods)
        }
    }

    // MARK: functional keys

    private func encodeLegacyFunctional(_ key: FunctionalKey, _ event: KeyEvent) -> [UInt8]? {
        var mods = event.modifiers
        mods.remove(.locks)
        // ⌘-arrow, ⌘-Home … are macOS shortcuts (or nothing); a Cisco prompt
        // would only print `CSI 1;9D` back at the user.
        if !mods.isDisjoint(with: [.super, .hyper]) { return nil }
        let m = Self.legacyModifier(mods)

        switch key {
        // Keys whose only form is a control byte; Alt prefixes ESC.
        case .escape, .enter, .tab, .backspace:
            return legacySpecialKeySequence(for: key, modifiers: mods, type: event.type)

        // Cursor keys and Home/End: SS3 in application-cursor mode, CSI
        // otherwise, `CSI 1 ; m X` as soon as a modifier is held.
        case .up:    return cursorKey("A", m)
        case .down:  return cursorKey("B", m)
        case .right: return cursorKey("C", m)
        case .left:  return cursorKey("D", m)
        case .home:  return cursorKey("H", m)
        case .end:   return cursorKey("F", m)

        // Editing keys.
        case .insert:   return tildeKey(2, m)
        case .delete:   return tildeKey(3, m)
        case .pageUp:   return tildeKey(5, m)
        case .pageDown: return tildeKey(6, m)

        // F1–F4 are the SS3 block, F5–F20 the tilde block.
        case .f1: return pfKey("P", m)
        case .f2: return pfKey("Q", m)
        case .f3: return pfKey("R", m)
        case .f4: return pfKey("S", m)
        case .f5:  return tildeKey(15, m)
        case .f6:  return tildeKey(17, m)
        case .f7:  return tildeKey(18, m)
        case .f8:  return tildeKey(19, m)
        case .f9:  return tildeKey(20, m)
        case .f10: return tildeKey(21, m)
        case .f11: return tildeKey(23, m)
        case .f12: return tildeKey(24, m)
        case .f13: return tildeKey(25, m)
        case .f14: return tildeKey(26, m)
        case .f15: return tildeKey(28, m)
        case .f16: return tildeKey(29, m)
        case .f17: return tildeKey(31, m)
        case .f18: return tildeKey(32, m)
        case .f19: return tildeKey(33, m)
        case .f20: return tildeKey(34, m)

        // The keypad's navigation half is indistinguishable from the main one.
        case .keypadUp:       return cursorKey("A", m)
        case .keypadDown:     return cursorKey("B", m)
        case .keypadRight:    return cursorKey("C", m)
        case .keypadLeft:     return cursorKey("D", m)
        case .keypadHome:     return cursorKey("H", m)
        case .keypadEnd:      return cursorKey("F", m)
        case .keypadInsert:   return tildeKey(2, m)
        case .keypadDelete:   return tildeKey(3, m)
        case .keypadPageUp:   return tildeKey(5, m)
        case .keypadPageDown: return tildeKey(6, m)
        case .keypadBegin:
            return applyAlt(applicationKeypad ? ss3("E") : csi("E"), modifiers: mods)

        // The keypad proper: `SS3 p`…`SS3 y` and friends in application mode,
        // the plain character otherwise.
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
             .keypadAdd, .keypadEnter, .keypadEqual, .keypadSeparator:
            guard let (appLetter, plain) = Self.keypadForms(key) else { return nil }
            let bytes = applicationKeypad ? ss3(appLetter) : Array(plain.utf8)
            return applyAlt(bytes, modifiers: mods)

        // F21–F35, Menu, the lock keys, media keys and the bare modifiers have
        // no legacy sequence — they exist only in the kitty protocol.
        default:
            return nil
        }
    }

    private func cursorKey(_ letter: String, _ m: Int) -> [UInt8] {
        if m == 0 {
            return applicationCursorKeys ? ss3(letter) : csi(letter)
        }
        return csi("1;\(m + 1)\(letter)")
    }

    private func pfKey(_ letter: String, _ m: Int) -> [UInt8] {
        m == 0 ? ss3(letter) : csi("1;\(m + 1)\(letter)")
    }

    private func tildeKey(_ number: Int, _ m: Int) -> [UInt8] {
        m == 0 ? csi("\(number)~") : csi("\(number);\(m + 1)~")
    }

    /// (application-keypad letter, the character the key types otherwise).
    static func keypadForms(_ key: FunctionalKey) -> (String, String)? {
        switch key {
        case .keypad0: return ("p", "0")
        case .keypad1: return ("q", "1")
        case .keypad2: return ("r", "2")
        case .keypad3: return ("s", "3")
        case .keypad4: return ("t", "4")
        case .keypad5: return ("u", "5")
        case .keypad6: return ("v", "6")
        case .keypad7: return ("w", "7")
        case .keypad8: return ("x", "8")
        case .keypad9: return ("y", "9")
        case .keypadMultiply:  return ("j", "*")
        case .keypadAdd:       return ("k", "+")
        case .keypadSeparator: return ("l", ",")
        case .keypadSubtract:  return ("m", "-")
        case .keypadDecimal:   return ("n", ".")
        case .keypadDivide:    return ("o", "/")
        case .keypadEnter:     return ("M", "\r")
        case .keypadEqual:     return ("X", "=")
        default: return nil
        }
    }

    /// Enter / Escape / Tab / Backspace — the four keys that are a control byte
    /// in every mode. Shift-Tab is the one exception (`CSI Z`).
    private func legacySpecialKeySequence(for key: FunctionalKey,
                                          modifiers: KeyModifiers,
                                          type: KeyEventType) -> [UInt8]? {
        if type == .release { return nil }
        let sequence: [UInt8]
        switch key {
        case .enter:
            sequence = lineFeedNewline ? [C0.cr, C0.lf] : [C0.cr]
        case .escape:
            sequence = [C0.esc]
        case .backspace:
            // Ctrl-Backspace is always BS; otherwise the user's preference.
            let base: UInt8 = modifiers.contains(.ctrl)
                ? C0.bs
                : (backspaceSendsControlH ? C0.bs : C0.del)
            sequence = [base]
        case .tab:
            sequence = modifiers.contains(.shift)
                ? [C0.esc, C0.leftBracket, UInt8(ascii: "Z")]
                : [C0.ht]
        default:
            return nil
        }
        return applyAlt(sequence, modifiers: modifiers)
    }

    // MARK: text keys

    /// Alt: prefix ESC, or set the 8th bit (DECSET 1034), or nothing at all
    /// when the host wants the OS's own composed text (`altSendsEscape` off).
    private func applyAlt(_ payload: [UInt8], modifiers: KeyModifiers) -> [UInt8] {
        guard modifiers.contains(.alt), !payload.isEmpty else { return payload }
        if metaSendsEightBit, payload.count == 1, payload[0] < 0x80 {
            return [payload[0] | 0x80]
        }
        guard altSendsEscape else { return payload }
        return [C0.esc] + payload
    }

    /// A Unicode key: the control byte for a Ctrl chord, otherwise the text the
    /// OS produced, with Alt applied. Ported from SwiftTerm's
    /// `legacyTextKeySequence` (MIT), with the 8-bit meta and the Ctrl+Shift
    /// punctuation cases added.
    func legacyTextKeySequence(event: KeyEvent) -> [UInt8]? {
        if event.type == .release { return nil }
        guard case let .unicode(codepoint) = event.key,
              let scalar = Unicode.Scalar(codepoint) else { return nil }

        var modifiers = event.modifiers
        modifiers.remove(.locks)
        // ⌘/Hyper/Meta chords are the app's, not the terminal's.
        if !modifiers.isDisjoint(with: [.super, .hyper, .meta]) { return nil }

        // What the user sees on the key, which is what a Ctrl chord maps.
        let effective: Unicode.Scalar
        if modifiers.contains(.shift) {
            effective = event.shiftedKey.flatMap(Unicode.Scalar.init)
                ?? event.text?.unicodeScalars.first
                ?? scalar
        } else {
            effective = scalar
        }

        if modifiers.contains(.ctrl) {
            // A non-Latin layout (Thai Kedmanee) types `แ` on the C key: the
            // control byte comes from the key's US-layout identity, as
            // iTerm2/kitty do — otherwise ⌃C cannot interrupt a pager.
            let mapped = Self.legacyControlMapping(for: effective)
                ?? event.baseLayoutKey.flatMap(Unicode.Scalar.init).flatMap(Self.legacyControlMapping(for:))
            if let mapped {
                // Ctrl-Shift-letter is a UI shortcut everywhere; leave it alone.
                if modifiers.contains(.shift), Self.isLetter(effective) { return nil }
                return applyAlt([mapped], modifiers: modifiers)
            }
            if modifiers.contains(.shift) { return nil }
        }

        var payload: [UInt8]
        if modifiers.contains(.alt), altSendsEscape {
            // Option-as-Meta: the OS composed `∫` for ⌥b, but the program
            // wants ESC + `b` (readline M-b, IOS-XE / FortiOS line editing).
            // A non-Latin layout sends ESC + its own character.
            payload = Array(String(effective).utf8)
        } else if let text = event.text, !text.isEmpty {
            payload = Array(text.utf8)
        } else {
            payload = Array(String(effective).utf8)
        }
        if payload.isEmpty { return nil }
        return applyAlt(payload, modifiers: modifiers)
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5a) ||
        (scalar.value >= 0x61 && scalar.value <= 0x7a)
    }

    /// The byte Ctrl+<key> sends. Ported from SwiftTerm (MIT); the digits are
    /// xterm's table (Ctrl-2 = NUL … Ctrl-8 = DEL, the rest pass through).
    static func legacyControlMapping(for scalar: Unicode.Scalar) -> UInt8? {
        let mapping = controlMapping
        if let lower = String(scalar).lowercased().unicodeScalars.first,
           let mapped = mapping[lower] {
            return mapped
        }
        return mapping[scalar]
    }

    private static let controlMapping: [Unicode.Scalar: UInt8] = [
            " ": 0,
            "/": 31,
            "0": 48,
            "1": 49,
            "2": 0,
            "3": 27,
            "4": 28,
            "5": 29,
            "6": 30,
            "7": 31,
            "8": 127,
            "9": 57,
            "?": 127,
            "@": 0,
            "[": 27,
            "\\": 28,
            "]": 29,
            "^": 30,
            "_": 31,
            "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7,
            "h": 8, "i": 9, "j": 10, "k": 11, "l": 12, "m": 13, "n": 14,
            "o": 15, "p": 16, "q": 17, "r": 18, "s": 19, "t": 20, "u": 21,
            "v": 22, "w": 23, "x": 24, "y": 25, "z": 26,
            "~": 30,
        ]
}

// MARK: - Kitty keyboard protocol
//
// Straight port of SwiftTerm's `KittyKeyboardEncoder` (MIT), renamed onto our
// types. The shape of every branch is kept so its test suite ports 1:1.

extension KeyEncoder {

    private func encodeKitty(_ event: KeyEvent) -> [UInt8]? {
        let flags = kittyFlags
        let wantsAllKeys = flags.contains(.reportAllKeys)
        let wantsDisambiguate = flags.contains(.disambiguate) || wantsAllKeys
        let wantsEvents = flags.contains(.reportEvents)
        let wantsAlternates = flags.contains(.reportAlternates)
        let wantsText = wantsAllKeys && flags.contains(.reportText)
        let includeAssociatedText = wantsText &&
            event.type != .release &&
            !Self.modifiersPreventText(event.modifiers)

        if event.type == .release && !wantsEvents {
            return nil
        }
        if event.type == .release,
           wantsEvents,
           !wantsAllKeys,
           case let .functional(key) = event.key,
           key == .enter || key == .tab || key == .backspace {
            return nil
        }

        // While composing, only the plain modifier keys are reported, and only
        // in report-all-keys mode.
        if event.composing {
            guard case let .functional(key) = event.key,
                  wantsAllKeys,
                  Self.isModifierFunctionalKey(key) else {
                return nil
            }
        }

        // Modifier keys are only reported in report-all-keys mode.
        if !wantsAllKeys,
           case let .functional(key) = event.key,
           Self.isModifierFunctionalKey(key) {
            return nil
        }

        // During IME / dead-key commit flows Enter may carry committed text,
        // while Backspace is editing the preedit and must not reach the program.
        if let text = event.text, !text.isEmpty,
           case let .functional(key) = event.key,
           key == .enter || key == .backspace,
           !Self.containsControlScalars(text) {
            if key == .backspace {
                return nil
            }
            return Array(text.utf8)
        }

        if wantsAllKeys {
            switch event.key {
            case .functional(let key):
                if key == .enter || key == .tab || key == .backspace {
                    return encodeCsiU(event: event,
                                      overrideKeyCode: Self.functionalUnicodeCodepoint(for: key),
                                      includeText: includeAssociatedText,
                                      includeAlternates: wantsAlternates,
                                      includeEventType: wantsEvents,
                                      includeLocks: true)
                }
                return encodeKittyFunctionalKey(key,
                                                event: event,
                                                disambiguate: true,
                                                includeText: includeAssociatedText,
                                                includeEventType: wantsEvents,
                                                includeAlternates: wantsAlternates,
                                                includeLocks: true)
            case .unicode, .none:
                return encodeCsiU(event: event,
                                  includeText: includeAssociatedText,
                                  includeAlternates: wantsAlternates,
                                  includeEventType: wantsEvents,
                                  includeLocks: true)
            }
        }

        if let text = event.text, !text.isEmpty {
            switch event.key {
            case .unicode, .none:
                let hasAltOrCtrl = event.modifiers.contains(.alt) || event.modifiers.contains(.ctrl)
                if !wantsDisambiguate || !hasAltOrCtrl {
                    if event.type != .release {
                        return Array(text.utf8)
                    }
                    return nil
                }
            case .functional:
                break
            }
        }

        return encodeKittyNonText(event: event,
                                  disambiguate: wantsDisambiguate,
                                  includeEventType: wantsEvents,
                                  includeAlternates: wantsAlternates,
                                  includeLocks: true)
    }

    private func encodeKittyNonText(event: KeyEvent,
                                    disambiguate: Bool,
                                    includeEventType: Bool,
                                    includeAlternates: Bool,
                                    includeLocks: Bool) -> [UInt8]? {
        switch event.key {
        case .none:
            return encodeCsiU(event: event,
                              includeText: false,
                              includeAlternates: includeAlternates,
                              includeEventType: includeEventType,
                              includeLocks: includeLocks)
        case .unicode(let codepoint):
            if !disambiguate {
                if let legacy = legacyTextKeySequence(event: event) {
                    return legacy
                }
                var updated = event
                updated.text = nil
                return encodeCsiU(event: updated,
                                  includeText: false,
                                  includeAlternates: includeAlternates,
                                  includeEventType: includeEventType,
                                  includeLocks: includeLocks)
            }
            var updated = event
            updated.text = nil
            return encodeCsiU(event: updated,
                              overrideKeyCode: Int(codepoint),
                              includeText: false,
                              includeAlternates: includeAlternates,
                              includeEventType: includeEventType,
                              includeLocks: includeLocks)
        case .functional(let key):
            return encodeKittyFunctionalKey(key,
                                            event: event,
                                            disambiguate: disambiguate,
                                            includeText: false,
                                            includeEventType: includeEventType,
                                            includeAlternates: includeAlternates,
                                            includeLocks: includeLocks)
        }
    }

    private func encodeKittyFunctionalKey(_ key: FunctionalKey,
                                          event: KeyEvent,
                                          disambiguate: Bool,
                                          includeText: Bool,
                                          includeEventType: Bool,
                                          includeAlternates: Bool,
                                          includeLocks: Bool) -> [UInt8]? {
        let modifiers = Self.kittyModifiersValue(for: event.modifiers, includeLocks: includeLocks)
        let includeType = includeEventType && event.type != .press
        let wantsModifiersField = modifiers != 0 || includeType

        switch key {
        case .escape:
            if disambiguate {
                return encodeCsiU(event: event,
                                  overrideKeyCode: 27,
                                  includeText: false,
                                  includeAlternates: includeAlternates,
                                  includeEventType: includeEventType,
                                  includeLocks: includeLocks)
            }
            return legacySpecialKeySequence(for: key,
                                            modifiers: event.modifiers,
                                            type: event.type)
        case .enter, .tab, .backspace:
            if disambiguate && wantsModifiersField {
                return encodeCsiU(event: event,
                                  overrideKeyCode: Self.functionalUnicodeCodepoint(for: key),
                                  includeText: false,
                                  includeAlternates: includeAlternates,
                                  includeEventType: includeEventType,
                                  includeLocks: includeLocks)
            }
            return legacySpecialKeySequence(for: key,
                                            modifiers: event.modifiers,
                                            type: event.type)
        default:
            break
        }

        switch Self.functionalEncoding(for: key) {
        case .csiLetter(let letter):
            if !disambiguate && !wantsModifiersField {
                if usesSs3InLegacy(key: key) {
                    return [C0.esc, C0.bigO, letter]
                }
                return csi(String(Unicode.Scalar(letter)))
            }
            return buildCsiWithModifier(number: 1,
                                        modifiers: modifiers,
                                        eventType: includeType ? event.type : nil,
                                        terminator: String(Unicode.Scalar(letter)),
                                        omitDefaultNumber: true)
        case .csiTilde(let number):
            return buildCsiWithModifier(number: number,
                                        modifiers: modifiers,
                                        eventType: includeType ? event.type : nil,
                                        terminator: "~",
                                        omitDefaultNumber: false)
        case .csiU(let codepoint):
            var updated = event
            if !includeText {
                updated.text = nil
            }
            return encodeCsiU(event: updated,
                              overrideKeyCode: codepoint,
                              includeText: includeText,
                              includeAlternates: includeAlternates,
                              includeEventType: includeEventType,
                              includeLocks: includeLocks)
        }
    }

    private func encodeCsiU(event: KeyEvent,
                            overrideKeyCode: Int? = nil,
                            includeText: Bool,
                            includeAlternates: Bool,
                            includeEventType: Bool,
                            includeLocks: Bool) -> [UInt8] {
        let keyCode: Int
        if let override = overrideKeyCode {
            keyCode = override
        } else {
            switch event.key {
            case .unicode(let codepoint):
                keyCode = Int(codepoint)
            case .functional(let key):
                keyCode = Self.functionalUnicodeCodepoint(for: key) ?? 0
            case .none:
                keyCode = 0
            }
        }

        let modifiers = Self.kittyModifiersValue(for: event.modifiers, includeLocks: includeLocks)
        let includeType = includeEventType && event.type != .press
        let textCodepoints = includeText ? Self.textCodepoints(from: event.text) : nil
        let includeModifiersField = includeType || modifiers != 0

        var body = "\(keyCode)"
        if includeAlternates {
            let shifted = event.modifiers.contains(.shift) ? event.shiftedKey : nil
            let base = event.baseLayoutKey
            if shifted != nil || base != nil {
                if let shifted {
                    body += ":\(shifted)"
                } else {
                    body += ":"
                }
                if let base {
                    body += ":\(base)"
                }
            }
        }

        if includeModifiersField {
            let modValue = modifiers + 1
            if includeType {
                body += ";\(modValue):\(event.type.kittyValue)"
            } else {
                body += ";\(modValue)"
            }
        }

        if let textCodepoints, !textCodepoints.isEmpty {
            body += includeModifiersField ? ";" : ";;"
            body += textCodepoints.map(String.init).joined(separator: ":")
        }

        return csi("\(body)u")
    }

    private func buildCsiWithModifier(number: Int,
                                      modifiers: Int,
                                      eventType: KeyEventType?,
                                      terminator: String,
                                      omitDefaultNumber: Bool) -> [UInt8] {
        let includeField = modifiers != 0 || eventType != nil
        var payload = ""
        if !omitDefaultNumber || includeField || number != 1 {
            payload = "\(number)"
        }
        if includeField {
            if payload.isEmpty { payload = "\(number)" }
            let modValue = modifiers + 1
            if let eventType {
                payload += ";\(modValue):\(eventType.kittyValue)"
            } else {
                payload += ";\(modValue)"
            }
        }
        payload += terminator
        return csi(payload)
    }

    private static func kittyModifiersValue(for modifiers: KeyModifiers,
                                            includeLocks: Bool) -> Int {
        var filtered = modifiers
        if !includeLocks { filtered.remove(.locks) }
        return filtered.rawValue
    }

    private func usesSs3InLegacy(key: FunctionalKey) -> Bool {
        switch key {
        case .f1, .f2, .f3, .f4:
            return true
        case .up, .down, .left, .right, .home, .end:
            return applicationCursorKeys
        default:
            return false
        }
    }

    private static func textCodepoints(from text: String?) -> [Int]? {
        guard let text else { return nil }
        var codepoints: [Int] = []
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                continue
            }
            codepoints.append(Int(scalar.value))
        }
        return codepoints.isEmpty ? nil : codepoints
    }

    private static func modifiersPreventText(_ modifiers: KeyModifiers) -> Bool {
        let textPreventing: KeyModifiers = [.alt, .ctrl, .super, .hyper, .meta]
        return !modifiers.intersection(textPreventing).isEmpty
    }

    private static func containsControlScalars(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                return true
            }
        }
        return false
    }

    static func isModifierFunctionalKey(_ key: FunctionalKey) -> Bool {
        switch key {
        case .leftShift, .rightShift,
             .leftControl, .rightControl,
             .leftAlt, .rightAlt,
             .leftSuper, .rightSuper,
             .leftHyper, .rightHyper,
             .leftMeta, .rightMeta,
             .isoLevel3Shift, .isoLevel5Shift:
            return true
        default:
            return false
        }
    }

    enum FunctionalEncoding {
        case csiLetter(UInt8)
        case csiTilde(Int)
        case csiU(Int)
    }

    /// kitty's functional-key table. Note F3 is `CSI 13 ~` here, not the legacy
    /// `SS3 R` — that is the protocol's own disambiguation.
    static func functionalEncoding(for key: FunctionalKey) -> FunctionalEncoding {
        switch key {
        case .up:    return .csiLetter(UInt8(ascii: "A"))
        case .down:  return .csiLetter(UInt8(ascii: "B"))
        case .right: return .csiLetter(UInt8(ascii: "C"))
        case .left:  return .csiLetter(UInt8(ascii: "D"))
        case .home:  return .csiLetter(UInt8(ascii: "H"))
        case .end:   return .csiLetter(UInt8(ascii: "F"))
        case .f1:    return .csiLetter(UInt8(ascii: "P"))
        case .f2:    return .csiLetter(UInt8(ascii: "Q"))
        case .f3:    return .csiTilde(13)
        case .f4:    return .csiLetter(UInt8(ascii: "S"))
        case .keypadBegin: return .csiU(57427)
        case .insert:   return .csiTilde(2)
        case .delete:   return .csiTilde(3)
        case .pageUp:   return .csiTilde(5)
        case .pageDown: return .csiTilde(6)
        case .f5:  return .csiTilde(15)
        case .f6:  return .csiTilde(17)
        case .f7:  return .csiTilde(18)
        case .f8:  return .csiTilde(19)
        case .f9:  return .csiTilde(20)
        case .f10: return .csiTilde(21)
        case .f11: return .csiTilde(23)
        case .f12: return .csiTilde(24)
        case .menu: return .csiU(57363)
        case .f13: return .csiU(57376)
        case .f14: return .csiU(57377)
        case .f15: return .csiU(57378)
        case .f16: return .csiU(57379)
        case .f17: return .csiU(57380)
        case .f18: return .csiU(57381)
        case .f19: return .csiU(57382)
        case .f20: return .csiU(57383)
        case .f21: return .csiU(57384)
        case .f22: return .csiU(57385)
        case .f23: return .csiU(57386)
        case .f24: return .csiU(57387)
        case .f25: return .csiU(57388)
        case .f26: return .csiU(57389)
        case .f27: return .csiU(57390)
        case .f28: return .csiU(57391)
        case .f29: return .csiU(57392)
        case .f30: return .csiU(57393)
        case .f31: return .csiU(57394)
        case .f32: return .csiU(57395)
        case .f33: return .csiU(57396)
        case .f34: return .csiU(57397)
        case .f35: return .csiU(57398)
        case .capsLock:    return .csiU(57358)
        case .scrollLock:  return .csiU(57359)
        case .numLock:     return .csiU(57360)
        case .printScreen: return .csiU(57361)
        case .pause:       return .csiU(57362)
        case .keypad0: return .csiU(57399)
        case .keypad1: return .csiU(57400)
        case .keypad2: return .csiU(57401)
        case .keypad3: return .csiU(57402)
        case .keypad4: return .csiU(57403)
        case .keypad5: return .csiU(57404)
        case .keypad6: return .csiU(57405)
        case .keypad7: return .csiU(57406)
        case .keypad8: return .csiU(57407)
        case .keypad9: return .csiU(57408)
        case .keypadDecimal:   return .csiU(57409)
        case .keypadDivide:    return .csiU(57410)
        case .keypadMultiply:  return .csiU(57411)
        case .keypadSubtract:  return .csiU(57412)
        case .keypadAdd:       return .csiU(57413)
        case .keypadEnter:     return .csiU(57414)
        case .keypadEqual:     return .csiU(57415)
        case .keypadSeparator: return .csiU(57416)
        case .keypadLeft:      return .csiU(57417)
        case .keypadRight:     return .csiU(57418)
        case .keypadUp:        return .csiU(57419)
        case .keypadDown:      return .csiU(57420)
        case .keypadPageUp:    return .csiU(57421)
        case .keypadPageDown:  return .csiU(57422)
        case .keypadHome:      return .csiU(57423)
        case .keypadEnd:       return .csiU(57424)
        case .keypadInsert:    return .csiU(57425)
        case .keypadDelete:    return .csiU(57426)
        case .mediaPlay:          return .csiU(57428)
        case .mediaPause:         return .csiU(57429)
        case .mediaPlayPause:     return .csiU(57430)
        case .mediaReverse:       return .csiU(57431)
        case .mediaStop:          return .csiU(57432)
        case .mediaFastForward:   return .csiU(57433)
        case .mediaRewind:        return .csiU(57434)
        case .mediaTrackNext:     return .csiU(57435)
        case .mediaTrackPrevious: return .csiU(57436)
        case .mediaRecord:        return .csiU(57437)
        case .volumeDown: return .csiU(57438)
        case .volumeUp:   return .csiU(57439)
        case .volumeMute: return .csiU(57440)
        case .leftShift:    return .csiU(57441)
        case .leftControl:  return .csiU(57442)
        case .leftAlt:      return .csiU(57443)
        case .leftSuper:    return .csiU(57444)
        case .leftHyper:    return .csiU(57445)
        case .leftMeta:     return .csiU(57446)
        case .rightShift:   return .csiU(57447)
        case .rightControl: return .csiU(57448)
        case .rightAlt:     return .csiU(57449)
        case .rightSuper:   return .csiU(57450)
        case .rightHyper:   return .csiU(57451)
        case .rightMeta:    return .csiU(57452)
        case .isoLevel3Shift: return .csiU(57453)
        case .isoLevel5Shift: return .csiU(57454)
        case .escape, .enter, .tab, .backspace: return .csiU(0)
        }
    }

    static func functionalUnicodeCodepoint(for key: FunctionalKey) -> Int? {
        switch key {
        case .escape:    return 27
        case .enter:     return 13
        case .tab:       return 9
        case .backspace: return 127
        default:
            if case let .csiU(codepoint) = functionalEncoding(for: key) {
                return codepoint
            }
            return nil
        }
    }
}
