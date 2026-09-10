// SheepVT — CSI dispatch.
//
// One switch on (prefix, intermediate, final). Every parameter goes through
// `p`/`p1` so a missing, zero or absurd value can never index anything, and
// every handler that moves the cursor ends inside `restrictCursor`.
// Behaviour is xterm's, read from xterm.js `InputHandler.ts`.

extension Terminal {

    // MARK: - Parameter helpers

    /// Parameter `i` with the ECMA-48 "0 is meaningful" reading (default 0).
    @inline(__always)
    private func p(_ params: CSIParams, _ i: Int) -> Int { params.param(i, default: 0) }

    /// Parameter `i` with the "0 means 1" reading every counted command uses.
    @inline(__always)
    private func p1(_ params: CSIParams, _ i: Int) -> Int { params.param(i, default: 1, min: 1) }

    /// Counts that drive loops are clamped: a device that emits `CSI 99999999 L`
    /// must not make us spin.
    @inline(__always)
    private func clampRows(_ n: Int) -> Int { Swift.max(1, Swift.min(n, rows)) }

    @inline(__always)
    private func clampCols(_ n: Int) -> Int { Swift.max(1, Swift.min(n, cols)) }

    // MARK: - Entry point

    public func csiDispatch(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {
        // REP is the only sequence that cares whether printing came directly
        // before it, so snapshot and clear in one place.
        let afterPrint = lastActionWasPrint
        lastActionWasPrint = false

        // An overflowed parameter list means the sequence was longer than any
        // real one; xterm ignores it rather than acting on a truncation.
        guard !params.overflowed else { return }

        let inter: UInt8 = intermediates.count == 1 ? intermediates[intermediates.startIndex] : 0
        guard intermediates.count <= 1 else {
            unhandled(describe(prefix, intermediates, final))
            return
        }

        switch prefix {
        case 0:
            if inter == 0 {
                dispatchPlain(final: final, params: params, afterPrint: afterPrint)
            } else {
                dispatchIntermediate(inter: inter, final: final, params: params)
            }
        case UInt8(ascii: "?"):
            dispatchPrivate(inter: inter, final: final, params: params)
        case UInt8(ascii: ">"):
            dispatchGreater(final: final, params: params)
        case UInt8(ascii: "<"):
            dispatchLess(final: final, params: params)
        case UInt8(ascii: "="):
            dispatchEquals(final: final, params: params)
        default:
            unhandled(describe(prefix, intermediates, final))
        }
    }

    private func describe(_ prefix: UInt8, _ intermediates: ArraySlice<UInt8>, _ final: UInt8) -> String {
        var s = "CSI "
        if prefix != 0 { s.append(Character(UnicodeScalar(prefix))) }
        for i in intermediates { s.append(Character(UnicodeScalar(i))) }
        s.append(Character(UnicodeScalar(final)))
        return s
    }

    // MARK: - No prefix, no intermediate

    private func dispatchPlain(final: UInt8, params: CSIParams, afterPrint: Bool) {
        let b = buffer
        switch final {

        case UInt8(ascii: "A"): // CUU — stops at the top margin when inside the region
            let n = p1(params, 0)
            let toTop = b.y - b.scrollTop
            moveCursor(0, -(toTop >= 0 ? Swift.min(toTop, n) : n))

        case UInt8(ascii: "B"): // CUD
            let n = p1(params, 0)
            let toBottom = b.scrollBottom - b.y
            moveCursor(0, toBottom >= 0 ? Swift.min(toBottom, n) : n)

        case UInt8(ascii: "C"): // CUF
            moveCursor(p1(params, 0), 0)

        case UInt8(ascii: "D"): // CUB
            moveCursor(-p1(params, 0), 0)

        case UInt8(ascii: "E"): // CNL
            let n = p1(params, 0)
            let toBottom = b.scrollBottom - b.y
            moveCursor(0, toBottom >= 0 ? Swift.min(toBottom, n) : n)
            b.x = 0

        case UInt8(ascii: "F"): // CPL
            let n = p1(params, 0)
            let toTop = b.y - b.scrollTop
            moveCursor(0, -(toTop >= 0 ? Swift.min(toTop, n) : n))
            b.x = 0

        case UInt8(ascii: "G"), UInt8(ascii: "`"): // CHA / HPA
            setCursor(p1(params, 0) - 1, originRelativeRow())

        case UInt8(ascii: "H"), UInt8(ascii: "f"): // CUP / HVP
            let col = params.count >= 2 ? p1(params, 1) - 1 : 0
            setCursor(col, p1(params, 0) - 1)

        case UInt8(ascii: "I"): // CHT
            guard b.x < cols else { break }
            var n = clampCols(p1(params, 0))
            while n > 0 { b.x = nextTabStop(); n -= 1 }
            markDirty(b.y)

        case UInt8(ascii: "J"): // ED
            eraseInDisplay(params, respectProtect: false)

        case UInt8(ascii: "K"): // EL
            eraseInLine(params, respectProtect: false)

        case UInt8(ascii: "L"): // IL
            restrictCursor()
            guard b.y >= b.scrollTop, b.y <= b.scrollBottom else { break }
            b.insertLines(at: b.y, count: clampRows(p1(params, 0)), fill: pen.eraseCell)
            b.x = 0
            markDirty(rows: b.y...b.scrollBottom)

        case UInt8(ascii: "M"): // DL
            restrictCursor()
            guard b.y >= b.scrollTop, b.y <= b.scrollBottom else { break }
            b.deleteLines(at: b.y, count: clampRows(p1(params, 0)), fill: pen.eraseCell)
            b.x = 0
            markDirty(rows: b.y...b.scrollBottom)

        case UInt8(ascii: "@"): // ICH
            restrictCursor()
            b.row(b.y).insertCells(at: b.x, count: clampCols(p1(params, 0)), fill: pen.eraseCell)
            markDirty(b.y)

        case UInt8(ascii: "P"): // DCH
            restrictCursor()
            b.row(b.y).deleteCells(at: b.x, count: clampCols(p1(params, 0)), fill: pen.eraseCell)
            markDirty(b.y)

        case UInt8(ascii: "X"): // ECH
            restrictCursor()
            let n = clampCols(p1(params, 0))
            eraseInRow(b.y, from: b.x, to: Swift.min(cols, b.x + n), clearWrap: false, respectProtect: false)
            markDirty(b.y)

        case UInt8(ascii: "S"): // SU
            let n = Swift.min(p1(params, 0), b.scrollBottom - b.scrollTop + 1)
            b.scrollUp(n, fill: pen.eraseCell, wrapped: false)
            delegate?.scrolled(self, lines: n)
            markDirty(rows: b.scrollTop...b.scrollBottom)

        case UInt8(ascii: "T"): // SD
            let n = Swift.min(p1(params, 0), b.scrollBottom - b.scrollTop + 1)
            b.scrollDown(n, fill: pen.eraseCell)
            delegate?.scrolled(self, lines: -n)
            markDirty(rows: b.scrollTop...b.scrollBottom)

        case UInt8(ascii: "Z"): // CBT
            guard b.x < cols else { break }
            var n = clampCols(p1(params, 0))
            while n > 0 { b.x = previousTabStop(); n -= 1 }
            markDirty(b.y)

        case UInt8(ascii: "a"): // HPR
            moveCursor(p1(params, 0), 0)

        case UInt8(ascii: "d"): // VPA
            setCursor(b.x, p1(params, 0) - 1)

        case UInt8(ascii: "e"): // VPR
            moveCursor(0, p1(params, 0))

        case UInt8(ascii: "b"): // REP
            repeatPrecedingCharacter(params, afterPrint: afterPrint)

        case UInt8(ascii: "c"): // DA1 — "VT220 with ANSI colour"
            if p(params, 0) == 0 { send("\u{1b}[?62;22c") }

        case UInt8(ascii: "g"): // TBC
            switch p(params, 0) {
            case 0:
                if b.x >= 0, b.x < b.tabStops.count { b.tabStops[b.x] = false }
            case 3:
                for i in b.tabStops.indices { b.tabStops[i] = false }
            default:
                break
            }
            touch()

        case UInt8(ascii: "h"): // SM
            setANSIModes(params, enabled: true)

        case UInt8(ascii: "l"): // RM
            setANSIModes(params, enabled: false)

        case UInt8(ascii: "m"): // SGR
            selectGraphicRendition(params)

        case UInt8(ascii: "n"): // DSR
            deviceStatusReport(params, private: false)

        case UInt8(ascii: "r"): // DECSTBM
            setScrollRegion(params)

        case UInt8(ascii: "s"): // SCOSC
            saveCursor()

        case UInt8(ascii: "u"): // SCORC
            restoreCursor()

        case UInt8(ascii: "t"): // XTWINOPS
            windowOptions(params)

        default:
            unhandled("CSI \(Character(UnicodeScalar(final)))")
        }
    }

    /// The row CHA/HPA should keep — under DECOM `setCursor` re-applies the
    /// origin offset, so hand it the region-relative row back.
    private func originRelativeRow() -> Int {
        let b = buffer
        return modes.originMode ? b.y - b.scrollTop : b.y
    }

    // MARK: - Intermediates (no prefix)

    private func dispatchIntermediate(inter: UInt8, final: UInt8, params: CSIParams) {
        switch (inter, final) {

        case (UInt8(ascii: " "), UInt8(ascii: "q")): // DECSCUSR
            let raw = params.count == 0 ? 1 : p(params, 0)
            let style = raw == 0 ? 1 : raw
            if let s = CursorStyle(rawValue: style) {
                setCursorStyle(s)
                modes.cursorBlink = style % 2 == 1
            }

        case (UInt8(ascii: "!"), UInt8(ascii: "p")): // DECSTR
            softReset()

        case (UInt8(ascii: "\""), UInt8(ascii: "q")): // DECSCA
            switch p(params, 0) {
            case 1: pen.bg |= Cell.BgFlag.protected
            default: pen.bg &= ~Cell.BgFlag.protected
            }
            touch()

        case (UInt8(ascii: " "), UInt8(ascii: "@")): // SL — scroll the region left
            columnOp(count: clampCols(p1(params, 0)), at: 0, insert: false)

        case (UInt8(ascii: " "), UInt8(ascii: "A")): // SR — scroll the region right
            columnOp(count: clampCols(p1(params, 0)), at: 0, insert: true)

        case (UInt8(ascii: "'"), UInt8(ascii: "}")): // DECIC — insert columns
            columnOp(count: clampCols(p1(params, 0)), at: buffer.x, insert: true)

        case (UInt8(ascii: "'"), UInt8(ascii: "~")): // DECDC — delete columns
            columnOp(count: clampCols(p1(params, 0)), at: buffer.x, insert: false)

        case (UInt8(ascii: "$"), UInt8(ascii: "p")): // DECRQM (ANSI)
            let m = p(params, 0)
            let v: Int
            switch m {
            case 4: v = modes.insert ? 1 : 2
            case 20: v = modes.lineFeedNewline ? 1 : 2
            default: v = 0
            }
            send("\u{1b}[\(m);\(v)$y")

        default:
            unhandled("CSI \(Character(UnicodeScalar(inter)))\(Character(UnicodeScalar(final)))")
        }
    }

    // MARK: - `?` prefix

    private func dispatchPrivate(inter: UInt8, final: UInt8, params: CSIParams) {
        if inter == UInt8(ascii: "$"), final == UInt8(ascii: "p") { // DECRQM (DEC private)
            let m = p(params, 0)
            send("\u{1b}[?\(m);\(decrqmValue(m))$y")
            return
        }
        guard inter == 0 else {
            unhandled("CSI ?\(Character(UnicodeScalar(inter)))\(Character(UnicodeScalar(final)))")
            return
        }
        switch final {
        case UInt8(ascii: "J"): // DECSED
            eraseInDisplay(params, respectProtect: true)
        case UInt8(ascii: "K"): // DECSEL
            eraseInLine(params, respectProtect: true)
        case UInt8(ascii: "h"): // DECSET
            setPrivateModes(params, enabled: true)
        case UInt8(ascii: "l"): // DECRST
            setPrivateModes(params, enabled: false)
        case UInt8(ascii: "n"): // DSR (DEC)
            deviceStatusReport(params, private: true)
        case UInt8(ascii: "u"): // kitty keyboard query
            send("\u{1b}[?\(kittyKeyboardFlags)u")
        default:
            unhandled("CSI ?\(Character(UnicodeScalar(final)))")
        }
    }

    // MARK: - `>` `<` `=` prefixes

    private func dispatchGreater(final: UInt8, params: CSIParams) {
        switch final {
        case UInt8(ascii: "c"): // DA2 — "VT220, firmware 10, no cartridge"
            if p(params, 0) == 0 { send("\u{1b}[>1;10;0c") }
        case UInt8(ascii: "u"): // kitty keyboard push
            var stack = kittyStack
            if stack.count >= Terminal.kittyStackLimit { stack.removeFirst() }
            stack.append(kittyKeyboardFlags)
            kittyStack = stack
            setKittyFlags(p(params, 0))
        default:
            unhandled("CSI >\(Character(UnicodeScalar(final)))")
        }
    }

    private func dispatchLess(final: UInt8, params: CSIParams) {
        switch final {
        case UInt8(ascii: "u"): // kitty keyboard pop
            let count = Swift.min(p1(params, 0), Terminal.kittyStackLimit)
            var stack = kittyStack
            var flags = kittyKeyboardFlags
            for _ in 0..<count {
                // Popping the last entry restores it; popping past the bottom
                // of the stack is what resets the flags (kitty's spec — xterm.js
                // zeroes them as soon as the stack empties, which loses the
                // entry it just popped).
                if let top = stack.popLast() { flags = top } else { flags = 0; break }
            }
            kittyStack = stack
            setKittyFlags(flags)
        default:
            unhandled("CSI <\(Character(UnicodeScalar(final)))")
        }
    }

    private func dispatchEquals(final: UInt8, params: CSIParams) {
        switch final {
        case UInt8(ascii: "c"): // DA3 — unit id, all zeroes
            send("\u{1b}P!|00000000\u{1b}\\")
        case UInt8(ascii: "u"): // kitty keyboard set
            let flags = p(params, 0)
            let mode = params.count > 1 ? p1(params, 1) : 1
            switch mode {
            case 2: setKittyFlags(kittyKeyboardFlags | flags)
            case 3: setKittyFlags(kittyKeyboardFlags & ~flags)
            default: setKittyFlags(flags)
            }
        default:
            unhandled("CSI =\(Character(UnicodeScalar(final)))")
        }
    }

    // MARK: - Erasing

    /// Note the plain `restrictCursor()`: an erase cancels a pending wrap and
    /// acts on the last column, not on the phantom `cols` one. xterm.js keeps
    /// the phantom column here and skips fixture t0055-EL because of it; real
    /// xterm holds the wrap as a flag beside a column that never leaves the
    /// screen, and clamping reproduces that.
    private func eraseInDisplay(_ params: CSIParams, respectProtect: Bool) {
        restrictCursor()
        let b = buffer
        switch p(params, 0) {
        case 0: // below
            eraseInRow(b.y, from: b.x, to: cols, clearWrap: b.x == 0, respectProtect: respectProtect)
            if b.y + 1 < rows {
                for y in (b.y + 1)..<rows { resetRow(y, respectProtect: respectProtect) }
            }
            markDirty(rows: b.y...(rows - 1))

        case 1: // above
            eraseInRow(b.y, from: 0, to: b.x + 1, clearWrap: true, respectProtect: respectProtect)
            // The whole previous row went: the next one is no longer a
            // continuation of anything.
            if b.x + 1 >= cols, b.y + 1 < rows { b.row(b.y + 1).wrapped = false }
            for y in 0..<b.y { resetRow(y, respectProtect: respectProtect) }
            markDirty(rows: 0...b.y)

        case 2: // whole screen (contents only — the scrollback stays)
            for y in 0..<rows { resetRow(y, respectProtect: respectProtect) }
            markAllDirty()

        case 3: // scrollback
            b.clearScrollback()
            markAllDirty()

        default:
            break
        }
    }

    /// Same pending-wrap clamp as `eraseInDisplay`.
    private func eraseInLine(_ params: CSIParams, respectProtect: Bool) {
        restrictCursor()
        let b = buffer
        switch p(params, 0) {
        case 0:
            eraseInRow(b.y, from: b.x, to: cols, clearWrap: b.x == 0, respectProtect: respectProtect)
        case 1:
            eraseInRow(b.y, from: 0, to: b.x + 1, clearWrap: false, respectProtect: respectProtect)
        case 2:
            eraseInRow(b.y, from: 0, to: cols, clearWrap: true, respectProtect: respectProtect)
        default:
            return
        }
        markDirty(b.y)
    }

    /// Erase `[from, to)` of a screen row with the pen's background (BCE).
    /// DECSED/DECSEL skip cells DECSCA marked protected, which rules out the
    /// bulk `Row.fill` path.
    private func eraseInRow(_ y: Int, from: Int, to: Int, clearWrap: Bool, respectProtect: Bool) {
        guard y >= 0, y < rows else { return }
        let row = buffer.row(y)
        let lo = Swift.max(0, from)
        let hi = Swift.min(cols, to)
        guard lo < hi else {
            if clearWrap { row.wrapped = false }
            return
        }
        let blank = pen.eraseCell
        // An erase must never cut a wide character in half: take the other
        // half of a character straddling either edge of [lo, hi).
        if lo > 0, row[lo - 1].width == 2, !(respectProtect && row[lo - 1].isProtected) {
            row[lo - 1] = blank
        }
        if hi < cols, row[hi].isSpacer, !(respectProtect && row[hi].isProtected) {
            row[hi] = blank
        }
        if respectProtect {
            for c in lo..<hi where !row[c].isProtected { row[c] = blank }
        } else {
            row.fill(blank, from: lo, to: hi)
        }
        if clearWrap { row.wrapped = false }
    }

    // MARK: - Column operations (SL / SR / DECIC / DECDC)

    /// Shift every row of the scroll region sideways. All four sequences are
    /// the same operation with a different column and direction, and all four
    /// are no-ops when the cursor sits outside the margins.
    private func columnOp(count: Int, at col: Int, insert: Bool) {
        let b = buffer
        guard b.y >= b.scrollTop, b.y <= b.scrollBottom else { return }
        let start = Swift.max(0, Swift.min(col, cols - 1))
        let blank = pen.eraseCell
        for y in b.scrollTop...b.scrollBottom {
            let row = b.row(y)
            if insert {
                row.insertCells(at: start, count: count, fill: blank)
            } else {
                row.deleteCells(at: start, count: count, fill: blank)
            }
            row.wrapped = false
        }
        markDirty(rows: b.scrollTop...b.scrollBottom)
    }

    private func resetRow(_ y: Int, respectProtect: Bool) {
        eraseInRow(y, from: 0, to: cols, clearWrap: true, respectProtect: respectProtect)
    }

    // MARK: - REP

    private func repeatPrecedingCharacter(_ params: CSIParams, afterPrint: Bool) {
        guard afterPrint, let code = lastPrintedCode else { return }
        // A run long enough to fill the screen several times over is already
        // indistinguishable from a longer one; anything more is a runaway.
        let n = Swift.min(p1(params, 0), Swift.min(Terminal.maxRepeat, cols * rows))
        for _ in 0..<n { print(code) }
    }

    static let maxRepeat = 100_000

    // MARK: - Modes

    private func setANSIModes(_ params: CSIParams, enabled: Bool) {
        guard params.count > 0 else { return }   // a bare `CSI h` names no mode
        for i in 0..<params.count {
            switch p(params, i) {
            case 4: modes.insert = enabled
            case 20: modes.lineFeedNewline = enabled
            default: unhandled("CSI \(p(params, i))\(enabled ? "h" : "l")")
            }
        }
        touch()
    }

    private func setPrivateModes(_ params: CSIParams, enabled: Bool) {
        guard params.count > 0 else { return }
        for i in 0..<params.count {
            switch p(params, i) {
            case 1: modes.applicationCursorKeys = enabled

            case 3: // DECCOLM — recorded; the host owns the window size
                modes.column132 = enabled

            case 5: modes.reverseVideo = enabled; markAllDirty()

            case 6: // DECOM — always homes the cursor
                modes.originMode = enabled
                setCursor(0, 0)

            case 7: modes.autoWrap = enabled
            case 12: modes.cursorBlink = enabled
            case 25: // DECTCEM — the cursor cell has to be repainted
                modes.cursorVisible = enabled
                markDirty(buffer.y)
            case 40: modes.allow80To132 = enabled
            case 45: modes.reverseWrap = enabled
            case 66: modes.applicationKeypad = enabled

            case 9: modes.mouseTracking = enabled ? .x10 : .none
            case 1000: modes.mouseTracking = enabled ? .normal : .none
            case 1002: modes.mouseTracking = enabled ? .buttonEvent : .none
            case 1003: modes.mouseTracking = enabled ? .anyEvent : .none
            case 1004: modes.focusEvents = enabled
            case 1005: modes.mouseEncoding = enabled ? .utf8 : .x10
            case 1006: modes.mouseEncoding = enabled ? .sgr : .x10
            case 1007: modes.alternateScroll = enabled
            case 1015: modes.mouseEncoding = enabled ? .urxvt : .x10
            case 1016: modes.mouseEncoding = enabled ? .sgrPixels : .x10
            case 1034: modes.sendMeta8 = enabled

            case 47:
                if enabled { activateAlternate(clearFirst: true) } else { activateNormal(clearAlternate: true) }

            case 1047:
                if enabled { activateAlternate(clearFirst: true) } else { activateNormal(clearAlternate: true) }

            case 1048:
                if enabled { saveCursor() } else { restoreCursor() }

            case 1049:
                if enabled {
                    saveCursor()
                    activateAlternate(clearFirst: true)
                } else {
                    activateNormal(clearAlternate: true)
                    restoreCursor()
                }

            case 2004: modes.bracketedPaste = enabled

            case 2026:
                modes.synchronizedOutput = enabled
                delegate?.synchronizedOutputChanged(self, enabled: enabled)

            default:
                unhandled("CSI ?\(p(params, i))\(enabled ? "h" : "l")")
            }
        }
        touch()
    }

    /// DECRPM value: 1 = set, 2 = reset, 0 = we do not know the mode.
    private func decrqmValue(_ m: Int) -> Int {
        func b(_ v: Bool) -> Int { v ? 1 : 2 }
        switch m {
        case 1: return b(modes.applicationCursorKeys)
        case 3: return modes.allow80To132 ? b(modes.column132) : 0
        case 5: return b(modes.reverseVideo)
        case 6: return b(modes.originMode)
        case 7: return b(modes.autoWrap)
        case 9: return b(modes.mouseTracking == .x10)
        case 12: return b(modes.cursorBlink)
        case 25: return b(modes.cursorVisible)
        case 40: return b(modes.allow80To132)
        case 45: return b(modes.reverseWrap)
        case 66: return b(modes.applicationKeypad)
        case 47, 1047, 1049: return b(isAlternate)
        case 1000: return b(modes.mouseTracking == .normal)
        case 1002: return b(modes.mouseTracking == .buttonEvent)
        case 1003: return b(modes.mouseTracking == .anyEvent)
        case 1004: return b(modes.focusEvents)
        case 1005: return b(modes.mouseEncoding == .utf8)
        case 1006: return b(modes.mouseEncoding == .sgr)
        case 1007: return b(modes.alternateScroll)
        case 1015: return b(modes.mouseEncoding == .urxvt)
        case 1016: return b(modes.mouseEncoding == .sgrPixels)
        case 1034: return b(modes.sendMeta8)
        case 1048: return 1 // xterm always reports "set"
        case 2004: return b(modes.bracketedPaste)
        case 2026: return b(modes.synchronizedOutput)
        default: return 0
        }
    }

    // MARK: - Reports

    private func deviceStatusReport(_ params: CSIParams, private isPrivate: Bool) {
        let b = buffer
        switch p(params, 0) {
        case 5 where !isPrivate:
            send("\u{1b}[0n")
        case 6:
            let row = (modes.originMode ? b.y - b.scrollTop : b.y) + 1
            let col = Swift.min(b.x, cols - 1) + 1
            send(isPrivate ? "\u{1b}[?\(row);\(col)R" : "\u{1b}[\(row);\(col)R")
        default:
            break
        }
    }

    private func setScrollRegion(_ params: CSIParams) {
        let b = buffer
        let top = p1(params, 0)
        var bottom = params.count >= 2 ? p(params, 1) : 0
        if bottom == 0 || bottom > rows { bottom = rows }
        guard bottom > top, top <= rows else { return }
        b.scrollTop = top - 1
        b.scrollBottom = bottom - 1
        setCursor(0, 0)
        touch()
    }

    private func windowOptions(_ params: CSIParams) {
        switch p(params, 0) {
        case 8: // resize request: CSI 8 ; rows ; cols t
            delegate?.resizeRequested(self, cols: p(params, 2), rows: p(params, 1))
        case 14: // text area size in pixels
            if let size = delegate?.pixelSize(self) {
                send("\u{1b}[4;\(size.height);\(size.width)t")
            }
        case 18: // text area size in characters
            send("\u{1b}[8;\(rows);\(cols)t")
        default:
            break
        }
    }
}
