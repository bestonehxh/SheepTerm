// SheepVT — MouseEncoder tests: every tracking mode × every encoding, the
// button and modifier bits, what each tracking mode filters out, the two
// coordinate limits, and DECSET 1007 alternate scroll.

import Testing
@testable import SheepVT

private func enc(_ tracking: MouseTracking, _ encoding: MouseEncoding) -> MouseEncoder {
    MouseEncoder(tracking: tracking, encoding: encoding)
}

private func press(_ button: MouseButton = .left,
                   col: Int = 0, row: Int = 0,
                   modifiers: KeyModifiers = []) -> MouseEvent {
    MouseEvent(button: button, action: .press, modifiers: modifiers, col: col, row: row)
}

private func text(_ bytes: [UInt8]?) -> String? {
    bytes.map { String(decoding: $0, as: UTF8.self) }
}

@Suite("Mouse encoder")
struct MouseEncoderTests {

    // MARK: tracking modes

    @Test("tracking off reports nothing",
          arguments: [MouseAction.press, .release, .motion])
    func trackingNone(action: MouseAction) {
        let e = MouseEvent(button: .left, action: action, col: 3, row: 4)
        #expect(enc(.none, .sgr).encode(e) == nil)
        #expect(enc(.none, .x10).encode(e) == nil)
    }

    @Test("x10 reports presses only")
    func x10Filters() {
        let m = enc(.x10, .x10)
        #expect(m.encode(press(col: 0, row: 0)) != nil)
        #expect(m.encode(MouseEvent(button: .left, action: .release, col: 0, row: 0)) == nil)
        #expect(m.encode(MouseEvent(button: .left, action: .motion, col: 0, row: 0)) == nil)
    }

    @Test("x10 drops the modifier bits")
    func x10DropsModifiers() {
        let m = enc(.x10, .x10)
        #expect(m.encode(press(modifiers: [.ctrl, .shift, .alt]))
                == m.encode(press()))
    }

    @Test("normal tracking reports press and release but no motion")
    func normalFilters() {
        let m = enc(.normal, .sgr)
        #expect(text(m.encode(press(col: 2, row: 3))) == "\u{1b}[<0;3;4M")
        #expect(text(m.encode(MouseEvent(button: .left, action: .release, col: 2, row: 3)))
                == "\u{1b}[<0;3;4m")
        #expect(m.encode(MouseEvent(button: .left, action: .motion, col: 2, row: 3)) == nil)
    }

    @Test("button-event tracking reports motion only while a button is down")
    func buttonEventFilters() {
        let m = enc(.buttonEvent, .sgr)
        #expect(text(m.encode(MouseEvent(button: .left, action: .motion, col: 2, row: 3)))
                == "\u{1b}[<32;3;4M")
        #expect(m.encode(MouseEvent(button: .none, action: .motion, col: 2, row: 3)) == nil)
    }

    @Test("any-event tracking reports bare motion as button 35")
    func anyEventFilters() {
        let m = enc(.anyEvent, .sgr)
        #expect(text(m.encode(MouseEvent(button: .none, action: .motion, col: 2, row: 3)))
                == "\u{1b}[<35;3;4M")
        #expect(text(m.encode(MouseEvent(button: .right, action: .motion, col: 2, row: 3)))
                == "\u{1b}[<34;3;4M")
    }

    // MARK: encodings

    @Test("x10 encoding is CSI M plus three offset bytes")
    func x10Encoding() {
        #expect(enc(.normal, .x10).encode(press(col: 0, row: 0))
                == [0x1b, 0x5b, 0x4d, 32, 33, 33])
        #expect(enc(.normal, .x10).encode(press(.right, col: 10, row: 20))
                == [0x1b, 0x5b, 0x4d, 34, 43, 53])
    }

    @Test("x10 encoding spells a release as button 3")
    func x10Release() {
        #expect(enc(.normal, .x10).encode(
            MouseEvent(button: .left, action: .release, col: 0, row: 0))
                == [0x1b, 0x5b, 0x4d, 35, 33, 33])
    }

    @Test("utf8 encoding matches x10 below the 128 boundary")
    func utf8Small() {
        #expect(enc(.normal, .utf8).encode(press(col: 0, row: 0))
                == [0x1b, 0x5b, 0x4d, 32, 33, 33])
    }

    @Test("sgr keeps the button on release and ends with m")
    func sgrEncoding() {
        let m = enc(.normal, .sgr)
        #expect(text(m.encode(press(.middle, col: 4, row: 5))) == "\u{1b}[<1;5;6M")
        #expect(text(m.encode(MouseEvent(button: .middle, action: .release, col: 4, row: 5)))
                == "\u{1b}[<1;5;6m")
    }

    @Test("urxvt is one decimal parameter with the +32 offset")
    func urxvtEncoding() {
        let m = enc(.normal, .urxvt)
        #expect(text(m.encode(press(.right, col: 4, row: 5))) == "\u{1b}[34;5;6M")
        #expect(text(m.encode(MouseEvent(button: .right, action: .release, col: 4, row: 5)))
                == "\u{1b}[35;5;6M")
    }

    @Test("sgrPixels reports pixels, and falls back to cells without them")
    func sgrPixelsEncoding() {
        let m = enc(.normal, .sgrPixels)
        #expect(text(m.encode(MouseEvent(button: .left, action: .press, col: 4, row: 5,
                                         pixelX: 123, pixelY: 456)))
                == "\u{1b}[<0;123;456M")
        #expect(text(m.encode(MouseEvent(button: .left, action: .release, col: 4, row: 5,
                                         pixelX: 123, pixelY: 456)))
                == "\u{1b}[<0;123;456m")
        #expect(text(m.encode(press(col: 4, row: 5))) == "\u{1b}[<0;5;6M")
    }

    @Test("every tracking mode encodes a press in every encoding",
          arguments: [MouseTracking.x10, .normal, .buttonEvent, .anyEvent])
    func everyTrackingEveryEncoding(tracking: MouseTracking) {
        for encoding: MouseEncoding in [.x10, .utf8, .sgr, .urxvt, .sgrPixels] {
            #expect(enc(tracking, encoding).encode(press(col: 1, row: 1)) != nil,
                    "\(tracking) × \(encoding)")
        }
    }

    // MARK: buttons and modifiers

    @Test("button codes",
          arguments: [(MouseButton.left, 0), (.middle, 1), (.right, 2),
                      (.wheelUp, 64), (.wheelDown, 65), (.wheelLeft, 66), (.wheelRight, 67),
                      (.button8, 128), (.button9, 129), (.button10, 130), (.button11, 131)])
    func buttonCodes(button: MouseButton, code: Int) {
        #expect(text(enc(.normal, .sgr).encode(press(button, col: 0, row: 0)))
                == "\u{1b}[<\(code);1;1M")
    }

    @Test("modifier bits: shift 4, alt 8, ctrl 16",
          arguments: [(KeyModifiers.shift, 4), (.alt, 8), (.meta, 8), (.ctrl, 16)])
    func modifierBits(modifier: KeyModifiers, delta: Int) {
        #expect(text(enc(.normal, .sgr).encode(press(modifiers: modifier)))
                == "\u{1b}[<\(delta);1;1M")
    }

    @Test("modifier bits add up")
    func modifiersCombine() {
        #expect(text(enc(.normal, .sgr).encode(press(modifiers: [.shift, .alt, .ctrl])))
                == "\u{1b}[<28;1;1M")
        // locks never take part
        #expect(text(enc(.normal, .sgr).encode(press(modifiers: [.capsLock, .numLock])))
                == "\u{1b}[<0;1;1M")
    }

    @Test("buttons 8–11 survive a legacy encoding")
    func highButtonsLegacy() {
        #expect(enc(.normal, .x10).encode(press(.button8, col: 0, row: 0))
                == [0x1b, 0x5b, 0x4d, 160, 33, 33])
        // 128 + 32 = 160 needs two bytes in the utf8 encoding
        #expect(enc(.normal, .utf8).encode(press(.button8, col: 0, row: 0))
                == [0x1b, 0x5b, 0x4d, 0xC2, 0xA0, 33, 33])
    }

    @Test("the wheel reports in every tracking mode that is on")
    func wheel() {
        #expect(text(enc(.x10, .sgr).encode(press(.wheelUp))) == "\u{1b}[<64;1;1M")
        #expect(text(enc(.anyEvent, .sgr).encode(press(.wheelDown, modifiers: [.shift])))
                == "\u{1b}[<69;1;1M")
    }

    // MARK: coordinate limits

    @Test("x10 spells coordinates up to 223 and drops the rest")
    func x10CoordinateLimit() {
        let m = enc(.normal, .x10)
        // 1-based 223 → byte 255, the last one that fits.
        #expect(m.encode(press(col: 222, row: 0)) == [0x1b, 0x5b, 0x4d, 32, 255, 33])
        // 1-based 224 would need 256.
        #expect(m.encode(press(col: 223, row: 0)) == nil)
        #expect(m.encode(press(col: 0, row: 223)) == nil)
        #expect(m.encode(press(col: 1000, row: 0)) == nil)
    }

    @Test("utf8 switches to two bytes at 128 and gives up past 2047")
    func utf8CoordinateLimit() {
        let m = enc(.normal, .utf8)
        // 1-based 95 → 127, still one byte.
        #expect(m.encode(press(col: 94, row: 0)) == [0x1b, 0x5b, 0x4d, 32, 127, 33])
        // 1-based 96 → 128, two bytes.
        #expect(m.encode(press(col: 95, row: 0)) == [0x1b, 0x5b, 0x4d, 32, 0xC2, 0x80, 33])
        // the last coordinate that fits: 1-based 2015 → 2047.
        #expect(m.encode(press(col: 2014, row: 0)) == [0x1b, 0x5b, 0x4d, 32, 0xDF, 0xBF, 33])
        #expect(m.encode(press(col: 2015, row: 0)) == nil)
        #expect(m.encode(press(col: 0, row: 2015)) == nil)
    }

    @Test("sgr and urxvt have no coordinate limit")
    func sgrUnlimited() {
        #expect(text(enc(.normal, .sgr).encode(press(col: 5000, row: 4000)))
                == "\u{1b}[<0;5001;4001M")
        #expect(text(enc(.normal, .urxvt).encode(press(col: 5000, row: 4000)))
                == "\u{1b}[32;5001;4001M")
    }

    // MARK: alternate scroll and the terminal snapshot

    @Test("alternate scroll sends cursor keys in both cursor-key modes")
    func alternateScroll() {
        #expect(text(MouseEncoder.alternateScroll(up: true, lines: 3,
                                                  applicationCursorKeys: false))
                == "\u{1b}[A\u{1b}[A\u{1b}[A")
        #expect(text(MouseEncoder.alternateScroll(up: false, lines: 2,
                                                  applicationCursorKeys: false))
                == "\u{1b}[B\u{1b}[B")
        #expect(text(MouseEncoder.alternateScroll(up: true, lines: 1,
                                                  applicationCursorKeys: true))
                == "\u{1b}OA")
        #expect(text(MouseEncoder.alternateScroll(up: false, lines: 1,
                                                  applicationCursorKeys: true))
                == "\u{1b}OB")
        #expect(MouseEncoder.alternateScroll(up: true, lines: 0,
                                             applicationCursorKeys: false) == [])
    }

    @Test("init(terminal:) snapshots the mouse modes")
    func terminalSnapshot() {
        let t = Terminal(cols: 80, rows: 24)
        var m = MouseEncoder(terminal: t)
        #expect(m.tracking == .none)
        #expect(m.encode(press()) == nil)

        t.feed("\u{1b}[?1000h")       // normal tracking
        t.feed("\u{1b}[?1006h")       // SGR encoding
        m = MouseEncoder(terminal: t)
        #expect(m.tracking == .normal)
        #expect(m.encoding == .sgr)
        #expect(text(m.encode(press(col: 9, row: 19))) == "\u{1b}[<0;10;20M")

        t.feed("\u{1b}[?1000l")
        m = MouseEncoder(terminal: t)
        #expect(m.tracking == .none)
        #expect(m.encode(press()) == nil)
    }
}
