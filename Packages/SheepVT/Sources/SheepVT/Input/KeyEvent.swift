// SheepVT — the key event the view hands to `KeyEncoder`.
//
// The view (phase 3) turns an NSEvent into one of these: a key identity
// (`KeyCode`), the modifiers that were down, whether it is a press/repeat/
// release, and the text the OS produced for it (after dead keys and the IME).
// Nothing here knows about AppKit, so the encoders can be tested headless.
//
// `FunctionalKey` and `KittyKeyboardFlags` follow the kitty keyboard protocol
// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/); the case list and the
// code points are ported from SwiftTerm's `KittyKeyboardEncoder.swift` and
// `KittyKeyboardProtocol.swift` (MIT).

/// Every key the kitty protocol names that is not a plain Unicode key.
public enum FunctionalKey: Sendable, Equatable, Hashable, CaseIterable {
    case escape
    case enter
    case tab
    case backspace
    case insert
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20
    case f21
    case f22
    case f23
    case f24
    case f25
    case f26
    case f27
    case f28
    case f29
    case f30
    case f31
    case f32
    case f33
    case f34
    case f35
    case menu
    case capsLock
    case scrollLock
    case numLock
    case printScreen
    case pause
    case keypad0
    case keypad1
    case keypad2
    case keypad3
    case keypad4
    case keypad5
    case keypad6
    case keypad7
    case keypad8
    case keypad9
    case keypadDecimal
    case keypadDivide
    case keypadMultiply
    case keypadSubtract
    case keypadAdd
    case keypadEnter
    case keypadEqual
    case keypadSeparator
    case keypadLeft
    case keypadRight
    case keypadUp
    case keypadDown
    case keypadPageUp
    case keypadPageDown
    case keypadHome
    case keypadEnd
    case keypadInsert
    case keypadDelete
    case keypadBegin
    case mediaPlay
    case mediaPause
    case mediaPlayPause
    case mediaReverse
    case mediaStop
    case mediaFastForward
    case mediaRewind
    case mediaTrackNext
    case mediaTrackPrevious
    case mediaRecord
    case volumeDown
    case volumeUp
    case volumeMute
    case leftShift
    case leftControl
    case leftAlt
    case leftSuper
    case leftHyper
    case leftMeta
    case rightShift
    case rightControl
    case rightAlt
    case rightSuper
    case rightHyper
    case rightMeta
    case isoLevel3Shift
    case isoLevel5Shift
}

/// What was pressed: a Unicode key (the *unshifted* code point of the physical
/// key, as kitty defines it), a functional key, or nothing (a bare modifier the
/// host could not name).
public enum KeyCode: Sendable, Equatable, Hashable {
    case unicode(UInt32)
    case functional(FunctionalKey)
    case none
}

/// Modifier bits. The numeric values are kitty's — the legacy xterm modifier
/// parameter is derived from them, it is not the same bitfield.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1 << 0)
    public static let alt      = KeyModifiers(rawValue: 1 << 1)
    public static let ctrl     = KeyModifiers(rawValue: 1 << 2)
    public static let `super`  = KeyModifiers(rawValue: 1 << 3)
    public static let hyper    = KeyModifiers(rawValue: 1 << 4)
    public static let meta     = KeyModifiers(rawValue: 1 << 5)
    public static let capsLock = KeyModifiers(rawValue: 1 << 6)
    public static let numLock  = KeyModifiers(rawValue: 1 << 7)

    /// The two lock states, which most encodings drop.
    public static let locks: KeyModifiers = [.capsLock, .numLock]
}

public enum KeyEventType: Sendable, Equatable, Hashable {
    case press
    case repeatPress
    case release

    /// The kitty event-type field: 1 press, 2 repeat, 3 release.
    var kittyValue: Int {
        switch self {
        case .press: return 1
        case .repeatPress: return 2
        case .release: return 3
        }
    }
}

public struct KeyEvent: Sendable {
    public var key: KeyCode
    public var modifiers: KeyModifiers
    public var type: KeyEventType
    /// Text the OS produced for the key (after dead keys / IME), nil for pure
    /// control keys.
    public var text: String?
    /// The code point this key produces with shift, on the current layout.
    public var shiftedKey: UInt32?
    /// The code point this key produces on the *first* (usually ASCII) layout.
    public var baseLayoutKey: UInt32?
    /// True while an IME/dead-key sequence is being composed.
    public var composing: Bool

    public init(key: KeyCode,
                modifiers: KeyModifiers = [],
                type: KeyEventType = .press,
                text: String? = nil,
                shiftedKey: UInt32? = nil,
                baseLayoutKey: UInt32? = nil,
                composing: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.type = type
        self.text = text
        self.shiftedKey = shiftedKey
        self.baseLayoutKey = baseLayoutKey
        self.composing = composing
    }
}

/// `CSI > flags u` — what the program asked the keyboard to report.
public struct KittyKeyboardFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let disambiguate     = KittyKeyboardFlags(rawValue: 1 << 0)
    public static let reportEvents     = KittyKeyboardFlags(rawValue: 1 << 1)
    public static let reportAlternates = KittyKeyboardFlags(rawValue: 1 << 2)
    public static let reportAllKeys    = KittyKeyboardFlags(rawValue: 1 << 3)
    public static let reportText       = KittyKeyboardFlags(rawValue: 1 << 4)

    /// The bits SheepVT understands; `Terminal` masks with this already.
    public static let known: KittyKeyboardFlags =
        [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText]
}

// MARK: - control bytes

/// The handful of C0 bytes the encoders emit, named so the tables read.
enum C0 {
    static let bs: UInt8 = 0x08
    static let ht: UInt8 = 0x09
    static let lf: UInt8 = 0x0a
    static let cr: UInt8 = 0x0d
    static let esc: UInt8 = 0x1b
    static let del: UInt8 = 0x7f
    /// `[` — the second byte of a CSI.
    static let leftBracket: UInt8 = 0x5b
    /// `O` — the second byte of an SS3.
    static let bigO: UInt8 = 0x4f
}
