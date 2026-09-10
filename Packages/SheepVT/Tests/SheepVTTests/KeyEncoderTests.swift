// SheepVT — KeyEncoder tests.
//
// Two suites: the kitty keyboard protocol (every case ported from SwiftTerm's
// `KittyKeyboardEncoderTests.swift`, MIT, same names) and the legacy xterm
// table from SPEC §D.

import Testing
@testable import SheepVT

// MARK: - helpers

private func encoder(flags: KittyKeyboardFlags = [],
                     applicationCursorKeys: Bool = false,
                     applicationKeypad: Bool = false,
                     backspaceSendsControlH: Bool = false,
                     altSendsEscape: Bool = true,
                     metaSendsEightBit: Bool = false) -> KeyEncoder {
    var e = KeyEncoder()
    e.kittyFlags = flags
    e.applicationCursorKeys = applicationCursorKeys
    e.applicationKeypad = applicationKeypad
    e.backspaceSendsControlH = backspaceSendsControlH
    e.altSendsEscape = altSendsEscape
    e.metaSendsEightBit = metaSendsEightBit
    return e
}

private func kitty(_ event: KeyEvent,
                   _ flags: KittyKeyboardFlags,
                   applicationCursorKeys: Bool = false,
                   backspaceSendsControlH: Bool = false) -> [UInt8]? {
    encoder(flags: flags,
            applicationCursorKeys: applicationCursorKeys,
            backspaceSendsControlH: backspaceSendsControlH).encode(event)
}

private func expectKitty(_ event: KeyEvent,
                         _ flags: KittyKeyboardFlags,
                         _ expected: String,
                         backspaceSendsControlH: Bool = false,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    let actual = kitty(event, flags, backspaceSendsControlH: backspaceSendsControlH)
    #expect(actual == Array(expected.utf8),
            "got \(String(describing: actual.map { String(decoding: $0, as: UTF8.self) }))",
            sourceLocation: sourceLocation)
}

private func expectNoKitty(_ event: KeyEvent,
                           _ flags: KittyKeyboardFlags,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(kitty(event, flags) == nil, sourceLocation: sourceLocation)
}

private func scalar(_ s: String) -> UInt32 { s.unicodeScalars.first!.value }

private let allFlags: KittyKeyboardFlags =
    [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText]

// MARK: - kitty keyboard protocol (ported from SwiftTerm)

@Suite("Kitty keyboard encoder")
struct KittyKeyboardEncoderTests {

    @Test("plain text with disambiguate")
    func plainTextWithDisambiguate() {
        expectKitty(KeyEvent(key: .unicode(97), text: "abcd"), [.disambiguate], "abcd")
    }

    @Test("repeat with just disambiguate")
    func repeatWithJustDisambiguate() {
        expectKitty(KeyEvent(key: .unicode(97), type: .repeatPress, text: "a"),
                    [.disambiguate], "a")
    }

    @Test("enter, backspace and tab keep their legacy bytes with disambiguate")
    func enterBackspaceTabWithDisambiguate() {
        expectKitty(KeyEvent(key: .functional(.enter)), [.disambiguate], "\r")
        expectKitty(KeyEvent(key: .functional(.backspace)), [.disambiguate], "\u{7f}")
        expectKitty(KeyEvent(key: .functional(.tab)), [.disambiguate], "\t")
    }

    @Test("shift-tab with disambiguate uses CSI u")
    func shiftTabWithDisambiguateUsesCsiU() {
        expectKitty(KeyEvent(key: .functional(.tab), modifiers: [.shift]),
                    [.disambiguate], "\u{1b}[9;2u")
    }

    @Test("shift-backspace with disambiguate uses CSI u")
    func shiftBackspaceWithDisambiguateUsesCsiU() {
        expectKitty(KeyEvent(key: .functional(.backspace), modifiers: [.shift]),
                    [.disambiguate], "\u{1b}[127;2u")
    }

    @Test("shift-enter with disambiguate uses CSI u")
    func shiftEnterWithDisambiguateUsesCsiU() {
        expectKitty(KeyEvent(key: .functional(.enter), modifiers: [.shift]),
                    [.disambiguate], "\u{1b}[13;2u")
    }

    @Test("report-all reports the enter release")
    func reportAllReleaseEnter() {
        expectKitty(KeyEvent(key: .functional(.enter), type: .release),
                    [.reportAllKeys, .reportEvents], "\u{1b}[13;1:3u")
    }

    @Test("enter release without report-all is suppressed")
    func enterReleaseWithoutReportAllIsSuppressed() {
        expectNoKitty(KeyEvent(key: .functional(.enter), type: .release),
                      [.disambiguate, .reportEvents])
    }

    @Test("report-all associated text without modifiers")
    func reportAllAssociatedTextWithoutModifiers() {
        expectKitty(KeyEvent(key: .unicode(97), text: "A"),
                    [.reportAllKeys, .reportText], "\u{1b}[97;;65u")
    }

    @Test("report-all associated text with shift")
    func reportAllAssociatedTextWithShift() {
        expectKitty(KeyEvent(key: .unicode(97), modifiers: [.shift], text: "A"),
                    [.reportAllKeys, .reportText], "\u{1b}[97;2;65u")
    }

    @Test("associated text drops control codes")
    func associatedTextDropsControlCodes() {
        expectKitty(KeyEvent(key: .unicode(97), text: "A\n"),
                    [.reportAllKeys, .reportText], "\u{1b}[97;;65u")
    }

    @Test("report-alternates emits shifted and base layout keys")
    func reportAlternatesShiftedAndBase() {
        expectKitty(KeyEvent(key: .unicode(97), modifiers: [.shift],
                             shiftedKey: scalar("A"), baseLayoutKey: scalar("c")),
                    [.disambiguate, .reportAlternates], "\u{1b}[97:65:99;2u")
    }

    @Test("report-alternates does not change text producing keys")
    func reportAlternatesDoesNotChangeTextProducingKeys() {
        let shiftedASCII = KeyEvent(key: .unicode(97), modifiers: [.shift],
                                    text: "A", shiftedKey: scalar("A"))
        let shiftedItalian = KeyEvent(key: .unicode(232), modifiers: [.shift],
                                      text: "é", shiftedKey: scalar("é"),
                                      baseLayoutKey: scalar("["))
        for flags: KittyKeyboardFlags in [
            [.disambiguate, .reportAlternates],
            [.disambiguate, .reportEvents, .reportAlternates],
        ] {
            expectKitty(shiftedASCII, flags, "A")
            expectKitty(shiftedItalian, flags, "é")
        }
    }

    @Test("a matching unshifted codepoint with text remains text")
    func matchingUnshiftedCodepointWithTextRemainsText() {
        expectKitty(KeyEvent(key: .unicode(65), modifiers: [.shift], text: "A",
                             baseLayoutKey: scalar("a")),
                    [.disambiguate, .reportAlternates], "A")
    }

    @Test("report-alternates with only a base layout key")
    func reportAlternatesBaseOnly() {
        expectKitty(KeyEvent(key: .unicode(97), baseLayoutKey: scalar("c")),
                    [.disambiguate, .reportAlternates], "\u{1b}[97::99u")
    }

    @Test("enter with all flags uses CSI u")
    func enterWithAllFlagsUsesCsiU() {
        expectKitty(KeyEvent(key: .functional(.enter)), allFlags, "\u{1b}[13u")
    }

    @Test("left control with all flags")
    func ctrlWithAllFlags() {
        expectKitty(KeyEvent(key: .functional(.leftControl), modifiers: [.ctrl]),
                    allFlags, "\u{1b}[57442;5u")
    }

    @Test("left control release keeps the ctrl modifier")
    func ctrlReleaseWithCtrlModSet() {
        expectKitty(KeyEvent(key: .functional(.leftControl), modifiers: [.ctrl], type: .release),
                    allFlags, "\u{1b}[57442;5:3u")
    }

    @Test("left shift is reported with report-all")
    func leftShiftWithReportAll() {
        expectKitty(KeyEvent(key: .functional(.leftShift)),
                    [.disambiguate, .reportAllKeys], "\u{1b}[57441u")
    }

    @Test("left shift without report-all is suppressed")
    func leftShiftWithoutReportAllIsSuppressed() {
        expectNoKitty(KeyEvent(key: .functional(.leftShift)),
                      [.disambiguate, .reportAlternates])
    }

    @Test("composing a plain key is suppressed")
    func composingWithNoModifierIsSuppressed() {
        expectNoKitty(KeyEvent(key: .unicode(97), modifiers: [.shift], composing: true),
                      [.disambiguate])
    }

    @Test("composing a modifier key with report-all is reported")
    func composingWithModifierAndReportAllIsReported() {
        expectKitty(KeyEvent(key: .functional(.leftShift), modifiers: [.shift], composing: true),
                    [.disambiguate, .reportAllKeys], "\u{1b}[57441;2u")
    }

    @Test("enter carrying committed dead-key text emits the text")
    func enterWithUtf8DeadKeyStateEmitsCommittedText() {
        expectKitty(KeyEvent(key: .functional(.enter), text: "A"),
                    [.disambiguate, .reportAlternates, .reportAllKeys], "A")
    }

    @Test("backspace carrying dead-key text is suppressed")
    func backspaceWithUtf8DeadKeyStateIsSuppressed() {
        expectNoKitty(KeyEvent(key: .functional(.backspace), text: "A"), allFlags)
    }

    @Test("delete with a control text still uses the delete sequence")
    func deleteWithControlUtf8StillUsesDeleteSequence() {
        expectKitty(KeyEvent(key: .functional(.delete), text: "\u{7f}"),
                    [.disambiguate, .reportAlternates, .reportAllKeys], "\u{1b}[3~")
    }

    @Test("up arrow with a control text still uses the arrow sequence")
    func upArrowWithControlUtf8StillUsesArrowSequence() {
        expectKitty(KeyEvent(key: .functional(.up), text: "\u{1e}"),
                    [.disambiguate], "\u{1b}[A")
    }

    @Test("keypad number includes its associated text in report-all")
    func keypadNumberIncludesAssociatedTextInReportAll() {
        expectKitty(KeyEvent(key: .functional(.keypad1), text: "1"),
                    allFlags, "\u{1b}[57400;;49u")
    }

    @Test("associated text is suppressed by the ctrl modifier")
    func associatedTextSuppressedByCtrlModifier() {
        expectKitty(KeyEvent(key: .unicode(106), modifiers: [.ctrl], text: "j"),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[106;5u")
    }

    @Test("associated text is omitted on release")
    func associatedTextOmittedOnRelease() {
        expectKitty(KeyEvent(key: .unicode(106), modifiers: [.shift], type: .release,
                             text: "J", shiftedKey: scalar("J")),
                    allFlags, "\u{1b}[106:74;2:3u")
    }

    @Test("report-alternates with caps lock")
    func reportAlternatesWithCapsLock() {
        expectKitty(KeyEvent(key: .unicode(106), modifiers: [.capsLock], text: "J"),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[106;65;74u")
    }

    @Test("report-alternates for shift-semicolon")
    func reportAlternatesColonShiftSemicolon() {
        expectKitty(KeyEvent(key: .unicode(59), modifiers: [.shift], text: ":",
                             shiftedKey: scalar(":")),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[59:58;2;58u")
    }

    @Test("report-alternates on a russian layout")
    func reportAlternatesRuLayout() {
        expectKitty(KeyEvent(key: .unicode(1095), text: "ч", baseLayoutKey: scalar(";")),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[1095::59;;1095u")
    }

    @Test("report-alternates on a shifted russian layout")
    func reportAlternatesRuLayoutShifted() {
        expectKitty(KeyEvent(key: .unicode(1095), modifiers: [.shift], text: "Ч",
                             shiftedKey: scalar("Ч"), baseLayoutKey: scalar(";")),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[1095:1063:59;2;1063u")
    }

    @Test("report-alternates on a russian layout with caps lock")
    func reportAlternatesRuLayoutCapsLock() {
        expectKitty(KeyEvent(key: .unicode(1095), modifiers: [.capsLock], text: "Ч",
                             baseLayoutKey: scalar(";")),
                    [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                    "\u{1b}[1095::59;65;1063u")
    }

    @Test("report-alternates on a hungarian layout release")
    func reportAlternatesHuLayoutRelease() {
        expectKitty(KeyEvent(key: .unicode(337), modifiers: [.ctrl], type: .release,
                             baseLayoutKey: scalar("[")),
                    allFlags, "\u{1b}[337::91;5:3u")
    }

    @Test("F3 uses CSI 13 ~ in the kitty protocol")
    func f3UsesCsi13Tilde() {
        expectKitty(KeyEvent(key: .functional(.f3)), [.disambiguate], "\u{1b}[13~")
    }

    @Test("keypad begin uses its kitty codepoint")
    func keypadBeginUsesKittyCodepoint() {
        expectKitty(KeyEvent(key: .functional(.keypadBegin)), [.disambiguate], "\u{1b}[57427u")
    }

    @Test("caps lock is included for a functional key")
    func capsLockModifierIncludedForFunctionalKey() {
        expectKitty(KeyEvent(key: .functional(.up), modifiers: [.capsLock]),
                    [.disambiguate], "\u{1b}[1;65A")
    }

    @Test("without disambiguate the arrows keep their legacy forms")
    func withoutDisambiguateArrowsAreLegacy() {
        // reportEvents alone still counts as "kitty on".
        expectKitty(KeyEvent(key: .functional(.up)), [.reportEvents], "\u{1b}[A")
        #expect(kitty(KeyEvent(key: .functional(.up)), [.reportEvents],
                      applicationCursorKeys: true) == Array("\u{1b}OA".utf8))
        expectKitty(KeyEvent(key: .functional(.f5)), [.reportEvents], "\u{1b}[15~")
    }

    @Test("backspaceSendsControlH is honoured under kitty too")
    func backspaceControlHUnderKitty() {
        expectKitty(KeyEvent(key: .functional(.backspace)), [.disambiguate],
                    "\u{08}", backspaceSendsControlH: true)
    }
}

// MARK: - legacy xterm encoding (SPEC §D)

@Suite("Legacy key encoder")
struct LegacyKeyEncoderTests {

    private func bytes(_ event: KeyEvent,
                       applicationCursorKeys: Bool = false,
                       applicationKeypad: Bool = false,
                       backspaceSendsControlH: Bool = false,
                       altSendsEscape: Bool = true,
                       metaSendsEightBit: Bool = false) -> [UInt8]? {
        encoder(applicationCursorKeys: applicationCursorKeys,
                applicationKeypad: applicationKeypad,
                backspaceSendsControlH: backspaceSendsControlH,
                altSendsEscape: altSendsEscape,
                metaSendsEightBit: metaSendsEightBit).encode(event)
    }

    private func expect(_ event: KeyEvent, _ expected: String,
                        applicationCursorKeys: Bool = false,
                        applicationKeypad: Bool = false,
                        backspaceSendsControlH: Bool = false,
                        altSendsEscape: Bool = true,
                        metaSendsEightBit: Bool = false,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = bytes(event,
                           applicationCursorKeys: applicationCursorKeys,
                           applicationKeypad: applicationKeypad,
                           backspaceSendsControlH: backspaceSendsControlH,
                           altSendsEscape: altSendsEscape,
                           metaSendsEightBit: metaSendsEightBit)
        #expect(actual == Array(expected.utf8), sourceLocation: sourceLocation)
    }

    // cursor keys

    @Test("arrows send CSI in normal cursor mode",
          arguments: [(FunctionalKey.up, "A"), (.down, "B"), (.right, "C"), (.left, "D")])
    func arrowsNormal(key: FunctionalKey, letter: String) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}[\(letter)")
    }

    @Test("arrows send SS3 in application cursor mode",
          arguments: [(FunctionalKey.up, "A"), (.down, "B"), (.right, "C"), (.left, "D")])
    func arrowsApplication(key: FunctionalKey, letter: String) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}O\(letter)",
               applicationCursorKeys: true)
    }

    @Test("a modified arrow is CSI 1;m even in application cursor mode")
    func arrowsWithModifiers() {
        expect(KeyEvent(key: .functional(.up), modifiers: [.shift]), "\u{1b}[1;2A")
        expect(KeyEvent(key: .functional(.up), modifiers: [.alt]), "\u{1b}[1;3A")
        expect(KeyEvent(key: .functional(.up), modifiers: [.ctrl]), "\u{1b}[1;5A")
        expect(KeyEvent(key: .functional(.up), modifiers: [.ctrl, .shift]), "\u{1b}[1;6A")
        expect(KeyEvent(key: .functional(.left), modifiers: [.meta]), "\u{1b}[1;9D")
        expect(KeyEvent(key: .functional(.up), modifiers: [.ctrl]), "\u{1b}[1;5A",
               applicationCursorKeys: true)
    }

    @Test("caps lock and num lock never reach the legacy modifier parameter")
    func locksAreIgnored() {
        expect(KeyEvent(key: .functional(.up), modifiers: [.capsLock, .numLock]), "\u{1b}[A")
    }

    @Test("home and end follow the cursor-key rules")
    func homeAndEnd() {
        expect(KeyEvent(key: .functional(.home)), "\u{1b}[H")
        expect(KeyEvent(key: .functional(.end)), "\u{1b}[F")
        expect(KeyEvent(key: .functional(.home)), "\u{1b}OH", applicationCursorKeys: true)
        expect(KeyEvent(key: .functional(.end)), "\u{1b}OF", applicationCursorKeys: true)
        expect(KeyEvent(key: .functional(.end), modifiers: [.ctrl]), "\u{1b}[1;5F")
    }

    // editing keys

    @Test("editing keys use the tilde forms",
          arguments: [(FunctionalKey.insert, 2), (.delete, 3), (.pageUp, 5), (.pageDown, 6)])
    func editingKeys(key: FunctionalKey, number: Int) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}[\(number)~")
        expect(KeyEvent(key: .functional(key), modifiers: [.shift]), "\u{1b}[\(number);2~")
    }

    // function keys

    @Test("F1–F4 are the SS3 block",
          arguments: [(FunctionalKey.f1, "P"), (.f2, "Q"), (.f3, "R"), (.f4, "S")])
    func functionKeys1to4(key: FunctionalKey, letter: String) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}O\(letter)")
        expect(KeyEvent(key: .functional(key), modifiers: [.ctrl]), "\u{1b}[1;5\(letter)")
    }

    @Test("F5–F12 are the tilde block",
          arguments: [(FunctionalKey.f5, 15), (.f6, 17), (.f7, 18), (.f8, 19),
                      (.f9, 20), (.f10, 21), (.f11, 23), (.f12, 24)])
    func functionKeys5to12(key: FunctionalKey, number: Int) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}[\(number)~")
    }

    @Test("F13–F20 continue the tilde block",
          arguments: [(FunctionalKey.f13, 25), (.f14, 26), (.f15, 28), (.f16, 29),
                      (.f17, 31), (.f18, 32), (.f19, 33), (.f20, 34)])
    func functionKeys13to20(key: FunctionalKey, number: Int) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}[\(number)~")
        expect(KeyEvent(key: .functional(key), modifiers: [.ctrl]), "\u{1b}[\(number);5~")
    }

    @Test("keys with no legacy sequence are left to the app")
    func noLegacySequence() {
        #expect(bytes(KeyEvent(key: .functional(.f21))) == nil)
        #expect(bytes(KeyEvent(key: .functional(.menu))) == nil)
        #expect(bytes(KeyEvent(key: .functional(.capsLock))) == nil)
        #expect(bytes(KeyEvent(key: .functional(.leftShift))) == nil)
        #expect(bytes(KeyEvent(key: .functional(.mediaPlay))) == nil)
        #expect(bytes(KeyEvent(key: .none)) == nil)
    }

    // tab / enter / escape / backspace

    @Test("tab, shift-tab and alt-tab")
    func tabKeys() {
        expect(KeyEvent(key: .functional(.tab)), "\t")
        expect(KeyEvent(key: .functional(.tab), modifiers: [.shift]), "\u{1b}[Z")
        expect(KeyEvent(key: .functional(.tab), modifiers: [.alt]), "\u{1b}\t")
    }

    @Test("enter and escape")
    func enterAndEscape() {
        expect(KeyEvent(key: .functional(.enter)), "\r")
        expect(KeyEvent(key: .functional(.enter), modifiers: [.alt]), "\u{1b}\r")
        expect(KeyEvent(key: .functional(.escape)), "\u{1b}")
        expect(KeyEvent(key: .functional(.escape), modifiers: [.alt]), "\u{1b}\u{1b}")
    }

    @Test("all three backspace variants")
    func backspaceVariants() {
        expect(KeyEvent(key: .functional(.backspace)), "\u{7f}")
        expect(KeyEvent(key: .functional(.backspace)), "\u{08}", backspaceSendsControlH: true)
        expect(KeyEvent(key: .functional(.backspace), modifiers: [.ctrl]), "\u{08}")
        expect(KeyEvent(key: .functional(.backspace), modifiers: [.alt]), "\u{1b}\u{7f}")
        expect(KeyEvent(key: .functional(.backspace), modifiers: [.alt]), "\u{1b}\u{08}",
               backspaceSendsControlH: true)
    }

    // control bytes

    @Test("ctrl+letter is the control byte",
          arguments: [("a", UInt8(1)), ("c", 3), ("h", 8), ("i", 9), ("j", 10),
                      ("m", 13), ("z", 26)])
    func ctrlLetters(letter: String, expected: UInt8) {
        let cp = letter.unicodeScalars.first!.value
        #expect(bytes(KeyEvent(key: .unicode(cp), modifiers: [.ctrl])) == [expected])
    }

    @Test("ctrl+punctuation is the control byte",
          arguments: [(" ", UInt8(0)), ("@", 0), ("[", 27), ("\\", 28), ("]", 29),
                      ("^", 30), ("_", 31), ("?", 127), ("/", 31)])
    func ctrlPunctuation(ch: String, expected: UInt8) {
        let cp = ch.unicodeScalars.first!.value
        #expect(bytes(KeyEvent(key: .unicode(cp), modifiers: [.ctrl])) == [expected])
    }

    @Test("ctrl+2..8 follow xterm's digit table",
          arguments: [("2", UInt8(0)), ("3", 27), ("4", 28), ("5", 29),
                      ("6", 30), ("7", 31), ("8", 127)])
    func ctrlDigits(digit: String, expected: UInt8) {
        let cp = digit.unicodeScalars.first!.value
        #expect(bytes(KeyEvent(key: .unicode(cp), modifiers: [.ctrl])) == [expected])
    }

    @Test("ctrl uses the shifted character the user actually typed")
    func ctrlUsesShiftedCharacter() {
        // ⌃⇧- on a US layout is ⌃_ = 0x1F.
        #expect(bytes(KeyEvent(key: .unicode(scalar("-")), modifiers: [.ctrl, .shift],
                               text: "_", shiftedKey: scalar("_"))) == [31])
        // ⌃⇧letter stays a UI shortcut.
        #expect(bytes(KeyEvent(key: .unicode(97), modifiers: [.ctrl, .shift])) == nil)
    }

    @Test("ctrl+alt+letter is ESC then the control byte")
    func ctrlAltLetter() {
        #expect(bytes(KeyEvent(key: .unicode(97), modifiers: [.ctrl, .alt])) == [0x1b, 1])
    }

    // text and Alt

    @Test("plain text is sent as its UTF-8")
    func plainText() {
        expect(KeyEvent(key: .unicode(97), text: "a"), "a")
        expect(KeyEvent(key: .unicode(97)), "a")
        expect(KeyEvent(key: .unicode(0xE9), text: "é"), "é")
        expect(KeyEvent(key: .none, text: "漢"), "漢")
    }

    @Test("alt prefixes ESC, or sets the 8th bit under DECSET 1034")
    func altForms() {
        expect(KeyEvent(key: .unicode(97), modifiers: [.alt], text: "a"), "\u{1b}a")
        #expect(bytes(KeyEvent(key: .unicode(97), modifiers: [.alt], text: "a"),
                      metaSendsEightBit: true) == [0xE1])
        // altSendsEscape off = let the OS's composed text through.
        expect(KeyEvent(key: .unicode(97), modifiers: [.alt], text: "é"), "é",
               altSendsEscape: false)
    }

    @Test("command chords belong to the app, not the terminal")
    func commandChords() {
        #expect(bytes(KeyEvent(key: .unicode(99), modifiers: [.super], text: "c")) == nil)
        #expect(bytes(KeyEvent(key: .unicode(99), modifiers: [.meta], text: "c")) == nil)
        // ⌘-arrow is a macOS shortcut, never `CSI 1;9D`; only an explicit
        // `.meta` reaches the xterm meta bit.
        #expect(bytes(KeyEvent(key: .functional(.left), modifiers: [.super])) == nil)
        #expect(bytes(KeyEvent(key: .functional(.home), modifiers: [.hyper])) == nil)
    }

    @Test("releases are never encoded, repeats are")
    func releaseAndRepeat() {
        #expect(bytes(KeyEvent(key: .unicode(97), type: .release, text: "a")) == nil)
        #expect(bytes(KeyEvent(key: .functional(.up), type: .release)) == nil)
        expect(KeyEvent(key: .unicode(97), type: .repeatPress, text: "a"), "a")
        expect(KeyEvent(key: .functional(.up), type: .repeatPress), "\u{1b}[A")
    }

    @Test("a composing key is left to the IME")
    func composingIsSuppressed() {
        #expect(bytes(KeyEvent(key: .unicode(97), text: "a", composing: true)) == nil)
    }

    // keypad

    @Test("the application keypad sends SS3 codes",
          arguments: [(FunctionalKey.keypad0, "p"), (.keypad1, "q"), (.keypad2, "r"),
                      (.keypad3, "s"), (.keypad4, "t"), (.keypad5, "u"), (.keypad6, "v"),
                      (.keypad7, "w"), (.keypad8, "x"), (.keypad9, "y"),
                      (.keypadMultiply, "j"), (.keypadAdd, "k"), (.keypadSeparator, "l"),
                      (.keypadSubtract, "m"), (.keypadDecimal, "n"), (.keypadDivide, "o"),
                      (.keypadEnter, "M"), (.keypadEqual, "X")])
    func applicationKeypadCodes(key: FunctionalKey, letter: String) {
        expect(KeyEvent(key: .functional(key)), "\u{1b}O\(letter)", applicationKeypad: true)
    }

    @Test("the numeric keypad types its characters")
    func numericKeypad() {
        expect(KeyEvent(key: .functional(.keypad1)), "1")
        expect(KeyEvent(key: .functional(.keypadAdd)), "+")
        expect(KeyEvent(key: .functional(.keypadDecimal)), ".")
        expect(KeyEvent(key: .functional(.keypadEnter)), "\r")
        expect(KeyEvent(key: .functional(.keypadSeparator)), ",")
    }

    @Test("keypad begin and the keypad navigation keys")
    func keypadNavigation() {
        expect(KeyEvent(key: .functional(.keypadBegin)), "\u{1b}[E")
        expect(KeyEvent(key: .functional(.keypadBegin)), "\u{1b}OE", applicationKeypad: true)
        expect(KeyEvent(key: .functional(.keypadUp)), "\u{1b}[A")
        expect(KeyEvent(key: .functional(.keypadUp)), "\u{1b}OA", applicationCursorKeys: true)
        expect(KeyEvent(key: .functional(.keypadHome)), "\u{1b}[H")
        expect(KeyEvent(key: .functional(.keypadDelete)), "\u{1b}[3~")
        expect(KeyEvent(key: .functional(.keypadPageUp)), "\u{1b}[5~")
    }

    @Test("alt on a keypad key still prefixes ESC")
    func altKeypad() {
        expect(KeyEvent(key: .functional(.keypad1), modifiers: [.alt]), "\u{1b}\u{1b}Oq",
               applicationKeypad: true)
        expect(KeyEvent(key: .functional(.keypad1), modifiers: [.alt]), "\u{1b}1")
    }
}

// MARK: - paste, focus, and the terminal snapshot

/// What `paste` produced before it was made single-pass: remove every
/// non-overlapping copy of the end marker left to right, and run that pass
/// again until one changes nothing. Kept here as the reference the fast
/// version has to agree with, byte for byte.
private func pasteFixedPoint(_ text: String, bracketed: Bool = true) -> [UInt8] {
    var body: [UInt8] = []
    var lastWasCR = false
    for b in text.utf8 {
        switch b {
        case 0x0d:
            body.append(0x0d)
            lastWasCR = true
        case 0x0a:
            if !lastWasCR { body.append(0x0d) }
            lastWasCR = false
        default:
            body.append(b)
            lastWasCR = false
        }
    }
    guard bracketed else { return body }
    let end = Array("\u{1b}[201~".utf8)
    while true {
        var out: [UInt8] = []
        var i = 0
        while i < body.count {
            if i + end.count <= body.count, Array(body[i ..< i + end.count]) == end {
                i += end.count
                continue
            }
            out.append(body[i])
            i += 1
        }
        if out.count == body.count { break }
        body = out
    }
    return Array("\u{1b}[200~".utf8) + body + end
}

@Suite("Key encoder helpers")
struct KeyEncoderHelperTests {

    @Test("paste turns newlines into CR")
    func pastePlain() {
        #expect(KeyEncoder.paste("a\nb", bracketed: false) == Array("a\rb".utf8))
        #expect(KeyEncoder.paste("a\r\nb", bracketed: false) == Array("a\rb".utf8))
        #expect(KeyEncoder.paste("a\rb", bracketed: false) == Array("a\rb".utf8))
    }

    @Test("a bracketed paste is wrapped")
    func pasteBracketed() {
        #expect(KeyEncoder.paste("hi", bracketed: true)
                == Array("\u{1b}[200~hi\u{1b}[201~".utf8))
    }

    @Test("a bracketed paste cannot smuggle its own end marker")
    func pasteStripsEndMarker() {
        #expect(KeyEncoder.paste("a\u{1b}[201~rm -rf /", bracketed: true)
                == Array("\u{1b}[200~arm -rf /\u{1b}[201~".utf8))
    }

    @Test("stripping the end marker matches the fixed point, in one pass")
    func pasteStripFixedPoint() {
        let marker = "\u{1b}[201~"
        var cases = [
            "",
            "no marker here at all",
            marker,
            marker + "abc",
            "abc" + marker,
            marker + marker,
            "a" + marker + "b" + marker + "c",
            // The splice the fixed-point loop existed for: removing the inner
            // copy joins its neighbours into a new one.
            "\u{1b}[20" + marker + "1~",
            "x\u{1b}[20" + marker + "1~y",
            // A marker that only exists because two halves met.
            "abc\u{1b}[20" + "1~def",
            // Partial markers that must survive untouched.
            "\u{1b}[20", "\u{1b}[201", marker + "~", "\u{1b}[\u{1b}[201~",
            // Newlines around a marker: normalisation runs first, as before.
            "a\r\n" + marker + "b\nc",
        ]
        for depth in [1, 2, 3, 8, 64, 200] {
            cases.append(String(repeating: "\u{1b}[20", count: depth)
                         + marker
                         + String(repeating: "1~", count: depth))
        }
        for text in cases {
            #expect(KeyEncoder.paste(text, bracketed: true) == pasteFixedPoint(text))
            #expect(KeyEncoder.paste(text, bracketed: false) == pasteFixedPoint(text, bracketed: false))
        }
    }

    @Test("stripping agrees with the fixed point on random marker soup")
    func pasteStripFuzz() {
        // Whole and half markers, so that a draw builds, splits and splices
        // them constantly — single random characters would practically never
        // spell out six particular bytes in a row.
        let pieces = ["\u{1b}[201~", "\u{1b}[20", "1~", "\u{1b}[", "201~", "\u{1b}", "~", "a", "\r\n"]
        var seed: UInt64 = 0x5EED_1234
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for _ in 0..<4000 {
            var text = ""
            for _ in 0..<next(12) { text += pieces[next(pieces.count)] }
            #expect(KeyEncoder.paste(text, bracketed: true) == pasteFixedPoint(text))
        }
    }

    @Test("a nested end marker strips in linear time")
    func pasteStripIsLinear() {
        func time(depth: Int) -> Double {
            let text = String(repeating: "\u{1b}[20", count: depth)
                + "\u{1b}[201~"
                + String(repeating: "1~", count: depth)
            let start = ContinuousClock.now
            let out = KeyEncoder.paste(text, bracketed: true)
            let elapsed = ContinuousClock.now - start
            #expect(out.count == 12)          // both brackets, nothing between
            return Double(elapsed.components.attoseconds) / 1e18
                 + Double(elapsed.components.seconds)
        }
        _ = time(depth: 256)                  // warm the allocator
        let small = time(depth: 4096)
        let big = time(depth: 8192)
        // Quadratic doubled the input and quadrupled the work: the deeper of
        // these two took seconds, this one takes microseconds. The bounds are
        // generous by orders of magnitude so that a loaded machine cannot make
        // them fail, and the floor keeps the ratio from meaning anything when
        // both runs are a fraction of a millisecond.
        #expect(big < 0.5)
        #expect(big < Swift.max(3 * small, 0.5))
    }

    @Test("focus in and out")
    func focus() {
        #expect(KeyEncoder.focus(true) == Array("\u{1b}[I".utf8))
        #expect(KeyEncoder.focus(false) == Array("\u{1b}[O".utf8))
    }

    @Test("init(terminal:) snapshots the modes")
    func terminalSnapshot() {
        let t = Terminal(cols: 80, rows: 24)
        var e = KeyEncoder(terminal: t)
        #expect(e.kittyFlags.isEmpty)
        #expect(!e.applicationCursorKeys)
        #expect(e.encode(KeyEvent(key: .functional(.up))) == Array("\u{1b}[A".utf8))

        t.feed("\u{1b}[?1h")          // DECCKM
        t.feed("\u{1b}=")             // DECKPAM
        t.feed("\u{1b}[?1034h")       // meta sends 8-bit
        e = KeyEncoder(terminal: t)
        #expect(e.applicationCursorKeys)
        #expect(e.applicationKeypad)
        #expect(e.metaSendsEightBit)
        #expect(e.encode(KeyEvent(key: .functional(.up))) == Array("\u{1b}OA".utf8))

        t.feed("\u{1b}[>1u")          // kitty: disambiguate
        e = KeyEncoder(terminal: t)
        #expect(e.kittyFlags == .disambiguate)
        #expect(e.encode(KeyEvent(key: .functional(.tab), modifiers: [.shift]))
                == Array("\u{1b}[9;2u".utf8))
    }
}

// MARK: - text input events (an IME commit)

/// Text the OS produced with no key behind it. The kitty spec's *Text as code
/// points* section: "if the terminal emulator receives no key information, the
/// key number ``0`` must be used to indicate a pure 'text event'", encoded
/// "with no modifiers", multiple code points "separated by colons" — and the
/// whole mechanism gated on *Report associated text* (`0b10000`), which is "an
/// enhancement to report_all_keys and is undefined if used without it".
@Suite("Text input events")
struct TextInputEventTests {

    private func textInput(_ text: String, _ flags: KittyKeyboardFlags) -> [UInt8] {
        encoder(flags: flags).textInput(text)
    }

    /// The spec's own example, one code point: `alt+a -> CSI 0 ; ; 229 u`.
    @Test("the spec's single-code-point example")
    func specExample() {
        #expect(textInput("å", [.reportAllKeys, .reportText])
                == Array("\u{1b}[0;;229u".utf8))
    }

    @Test("a multi-code-point commit is colon separated")
    func multipleCodePoints() {
        // 日 = U+65E5 = 26085, 本 = U+672C = 26412.
        #expect(textInput("日本", [.reportAllKeys, .reportText])
                == Array("\u{1b}[0;;26085:26412u".utf8))
        // Astral planes are one code point each, not surrogate pairs.
        #expect(textInput("🐑", [.reportAllKeys, .reportText])
                == Array("\u{1b}[0;;128017u".utf8))
    }

    /// Every other flag state keeps the bytes it sent before: the two bits
    /// together are the only thing that changes a commit.
    @Test("only report-all-keys + report-text changes a commit")
    func everyOtherFlagStateIsUtf8() {
        for raw in 0 ... 31 {
            let flags = KittyKeyboardFlags(rawValue: raw)
            let out = textInput("日本", flags)
            if flags.contains(.reportAllKeys), flags.contains(.reportText) {
                #expect(out == Array("\u{1b}[0;;26085:26412u".utf8), "flags \(raw)")
            } else {
                #expect(out == Array("日本".utf8), "flags \(raw)")
            }
        }
    }

    /// "This flag is an enhancement to report_all_keys and is undefined if used
    /// without it" — the same rule `encode` applies to a key's associated text,
    /// so a commit and a keystroke can never disagree about the mode.
    @Test("report-text alone is not enough")
    func reportTextWithoutReportAllKeys() {
        #expect(textInput("日本", [.reportText]) == Array("日本".utf8))
        #expect(textInput("日本", [.disambiguate, .reportEvents, .reportAlternates, .reportText])
                == Array("日本".utf8))
    }

    /// "The associated text must not contain control codes."
    @Test("control codes are dropped, and a commit of nothing else stays UTF-8")
    func controlCodes() {
        #expect(textInput("a\u{1}b", [.reportAllKeys, .reportText])
                == Array("\u{1b}[0;;97:98u".utf8))
        // Nothing reportable is left: send the text rather than swallow it.
        #expect(textInput("\r", allFlags) == Array("\r".utf8))
        #expect(textInput("", allFlags) == [])
    }

    /// The full flag set adds nothing: alternate keys and event types are key
    /// fields, and a text event has no key and no press/release.
    @Test("no alternate-key or event-type fields on a text event")
    func noKeyFields() {
        #expect(textInput("é", allFlags) == Array("\u{1b}[0;;233u".utf8))
    }

    /// A paste is not a text input event — the protocol is scoped to key events
    /// and never mentions paste, and its "no control codes" rule could not
    /// carry the CR a multi-line paste is made of. Bracketed paste is the only
    /// framing, in every flag state.
    @Test("a paste is untouched by the report-text flag")
    func pasteIsNotATextEvent() {
        let text = "show run\nshow ver\n"
        let bracketed = KeyEncoder.paste(text, bracketed: true)
        #expect(bracketed == Array("\u{1b}[200~show run\rshow ver\r\u{1b}[201~".utf8))
        // `paste` is static: there is no flag state it could consult, which is
        // the point — this pins that it stays that way.
        #expect(KeyEncoder.paste(text, bracketed: false) == Array("show run\rshow ver\r".utf8))
        #expect(encoder(flags: allFlags).textInput("show run") != bracketed)
    }
}
