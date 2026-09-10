// SheepVT — mouse events to bytes.
//
// Two independent switches decide everything: **what** the program asked to
// hear (`MouseTracking`, DECSET 9/1000/1002/1003) and **how** it wants it
// spelled (`MouseEncoding`, DECSET 1005/1006/1015/1016). The encoder is a
// snapshot of both, so the view can encode off the terminal's queue.
//
// Button code (xterm ctlseqs): left 0, middle 1, right 2, "no button" 3,
// + shift 4, + alt/meta 8, + ctrl 16, + motion 32, wheel 64…67,
// buttons 8–11 → 128…131. The legacy encodings replace the button with 3 on
// release (they cannot say which button came up); SGR keeps the button and
// ends the sequence with `m` instead of `M`.

public enum MouseButton: Sendable, Equatable, Hashable {
    case left, middle, right, none
    case wheelUp, wheelDown, wheelLeft, wheelRight
    case button8, button9, button10, button11

    /// The base code before modifier and motion bits.
    var code: Int {
        switch self {
        case .left: return 0
        case .middle: return 1
        case .right: return 2
        case .none: return 3
        case .wheelUp: return 64
        case .wheelDown: return 65
        case .wheelLeft: return 66
        case .wheelRight: return 67
        case .button8: return 128
        case .button9: return 129
        case .button10: return 130
        case .button11: return 131
        }
    }
}

public enum MouseAction: Sendable, Equatable, Hashable {
    case press, release, motion
}

public struct MouseEvent: Sendable {
    public var button: MouseButton
    public var action: MouseAction
    public var modifiers: KeyModifiers
    /// 0-based screen cell.
    public var col: Int
    public var row: Int
    /// Pixel position inside the view, for `.sgrPixels` (DECSET 1016).
    public var pixelX: Int?
    public var pixelY: Int?

    public init(button: MouseButton,
                action: MouseAction,
                modifiers: KeyModifiers = [],
                col: Int,
                row: Int,
                pixelX: Int? = nil,
                pixelY: Int? = nil) {
        self.button = button
        self.action = action
        self.modifiers = modifiers
        self.col = col
        self.row = row
        self.pixelX = pixelX
        self.pixelY = pixelY
    }
}

public struct MouseEncoder: Sendable {

    public var tracking: MouseTracking
    public var encoding: MouseEncoding

    public init(tracking: MouseTracking, encoding: MouseEncoding) {
        self.tracking = tracking
        self.encoding = encoding
    }

    /// Snapshot of `terminal.modes`.
    public init(terminal: Terminal) {
        tracking = terminal.modes.mouseTracking
        encoding = terminal.modes.mouseEncoding
    }

    /// The largest 1-based coordinate `.x10` can spell (value + 32 ≤ 255).
    public static let x10MaxCoordinate = 223
    /// The largest 1-based coordinate `.utf8` can spell (value + 32 ≤ 2047).
    public static let utf8MaxCoordinate = 2015

    /// Bytes to write, or nil when this event is not reported in this mode.
    public func encode(_ e: MouseEvent) -> [UInt8]? {
        guard let action = filter(e) else { return nil }

        // x10 is the 1978 protocol: presses only, and no modifier bits at all.
        var modifiers = e.modifiers
        if tracking == .x10 { modifiers = [] }

        let releaseLosesButton = (action == .release) && encoding != .sgr && encoding != .sgrPixels
        var code = releaseLosesButton ? MouseButton.none.code : e.button.code
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.alt) || modifiers.contains(.meta) { code += 8 }
        if modifiers.contains(.ctrl) { code += 16 }
        if action == .motion { code += 32 }

        switch encoding {
        case .x10:
            return encodeX10(code: code, col: e.col, row: e.row)
        case .utf8:
            return encodeUtf8(code: code, col: e.col, row: e.row)
        case .urxvt:
            return csi("\(code + 32);\(e.col + 1);\(e.row + 1)M")
        case .sgr:
            return csi("<\(code);\(e.col + 1);\(e.row + 1)\(action == .release ? "m" : "M")")
        case .sgrPixels:
            let x = e.pixelX ?? (e.col + 1)
            let y = e.pixelY ?? (e.row + 1)
            return csi("<\(code);\(x);\(y)\(action == .release ? "m" : "M")")
        }
    }

    /// Which events this tracking mode reports. Returns the action to encode,
    /// or nil to drop the event.
    private func filter(_ e: MouseEvent) -> MouseAction? {
        switch tracking {
        case .none:
            return nil
        case .x10:
            // Presses only. A wheel "press" still counts.
            return e.action == .press ? .press : nil
        case .normal:
            return e.action == .motion ? nil : e.action
        case .buttonEvent:
            // Motion is reported only while a button is held (drag).
            if e.action == .motion && e.button == .none { return nil }
            return e.action
        case .anyEvent:
            return e.action
        }
    }

    private func encodeX10(code: Int, col: Int, row: Int) -> [UInt8]? {
        let x = col + 1, y = row + 1
        guard x >= 1, y >= 1,
              x <= Self.x10MaxCoordinate, y <= Self.x10MaxCoordinate,
              code + 32 <= 255 else { return nil }
        return [C0.esc, C0.leftBracket, UInt8(ascii: "M"),
                UInt8(code + 32), UInt8(x + 32), UInt8(y + 32)]
    }

    private func encodeUtf8(code: Int, col: Int, row: Int) -> [UInt8]? {
        let x = col + 1, y = row + 1
        guard x >= 1, y >= 1,
              x <= Self.utf8MaxCoordinate, y <= Self.utf8MaxCoordinate else { return nil }
        var out: [UInt8] = [C0.esc, C0.leftBracket, UInt8(ascii: "M")]
        for value in [code + 32, x + 32, y + 32] {
            guard let bytes = Self.utf8Value(value) else { return nil }
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// DECSET 1005: a value under 128 is one byte, 128…2047 is two-byte UTF-8,
    /// anything larger cannot be spelled and drops the whole event.
    static func utf8Value(_ value: Int) -> [UInt8]? {
        if value < 0 { return nil }
        if value < 0x80 { return [UInt8(value)] }
        if value < 0x800 {
            return [UInt8(0xC0 | (value >> 6)), UInt8(0x80 | (value & 0x3F))]
        }
        return nil
    }

    private func csi(_ payload: String) -> [UInt8] {
        var bytes: [UInt8] = [C0.esc, C0.leftBracket]
        bytes.append(contentsOf: payload.utf8)
        return bytes
    }

    /// DECSET 1007: with tracking off, the alternate screen turns the wheel
    /// into cursor keys so `less` and `man` scroll.
    public static func alternateScroll(up: Bool, lines: Int, applicationCursorKeys: Bool) -> [UInt8] {
        guard lines > 0 else { return [] }
        let letter: UInt8 = up ? UInt8(ascii: "A") : UInt8(ascii: "B")
        let one: [UInt8] = [C0.esc, applicationCursorKeys ? C0.bigO : C0.leftBracket, letter]
        var out: [UInt8] = []
        out.reserveCapacity(one.count * lines)
        for _ in 0 ..< lines { out.append(contentsOf: one) }
        return out
    }
}
