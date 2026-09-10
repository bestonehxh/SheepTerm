// SheepVT — ESC dispatch (the sequences that carry no parameters).

extension Terminal {

    public func escDispatch(intermediates: ArraySlice<UInt8>, final: UInt8) {
        lastActionWasPrint = false
        let inter: UInt8 = intermediates.count >= 1 ? intermediates[intermediates.startIndex] : 0

        // Charset designation: ESC ( ) * + - . / <final>
        switch inter {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"):
            designateCharset(intermediate: inter, final: final)
            return
        case UInt8(ascii: "#"):
            if final == UInt8(ascii: "8") { screenAlignmentPattern() }
            else { unhandled("ESC #\(Character(UnicodeScalar(final)))") }
            return
        case UInt8(ascii: "%"):
            // ESC % G / ESC % @ — select UTF-8 / default. We are always UTF-8.
            return
        case 0:
            break
        default:
            unhandled("ESC \(Character(UnicodeScalar(inter)))\(Character(UnicodeScalar(final)))")
            return
        }

        switch final {
        case UInt8(ascii: "7"): // DECSC
            saveCursor()

        case UInt8(ascii: "8"): // DECRC
            restoreCursor()

        case UInt8(ascii: "D"): // IND
            restrictCursor()
            linefeed(clearWrapped: false)

        case UInt8(ascii: "E"): // NEL
            restrictCursor()
            buffer.x = 0
            linefeed(clearWrapped: false)

        case UInt8(ascii: "H"): // HTS
            let b = buffer
            if b.x >= 0, b.x < b.tabStops.count { b.tabStops[b.x] = true }
            touch()

        case UInt8(ascii: "M"): // RI
            restrictCursor()
            reverseIndex()

        case UInt8(ascii: "c"): // RIS
            reset()

        case UInt8(ascii: "="): // DECKPAM
            modes.applicationKeypad = true
            touch()

        case UInt8(ascii: ">"): // DECKPNM
            modes.applicationKeypad = false
            touch()

        case UInt8(ascii: "n"): // LS2 — locking shift G2 into GL
            glevel = 2
            touch()

        case UInt8(ascii: "o"): // LS3 — locking shift G3 into GL
            glevel = 3
            touch()

        case UInt8(ascii: "\\"): // ST — the tail of a string we already closed
            break

        default:
            unhandled("ESC \(Character(UnicodeScalar(final)))")
        }
    }

    // MARK: - Helpers

    private func designateCharset(intermediate: UInt8, final: UInt8) {
        let g: Int
        switch intermediate {
        case UInt8(ascii: "("): g = 0
        case UInt8(ascii: ")"), UInt8(ascii: "-"): g = 1
        case UInt8(ascii: "*"), UInt8(ascii: "."): g = 2
        default: g = 3
        }
        charsets[g] = Charsets.designation(for: final)
        touch()
    }

    /// DECALN (`ESC # 8`): fill the screen with `E`, reset the margins and go
    /// home. Used by vttest and, occasionally, by a device that wants a known
    /// state before drawing.
    private func screenAlignmentPattern() {
        noteVisibleGlyph()   // a screen full of E is very much visible output
        let b = buffer
        let cell = pen.cell(code: 0x45, width: 1) // 'E'
        for y in 0..<rows {
            let row = b.row(y)
            row.fill(cell)
            row.wrapped = false
        }
        b.scrollTop = 0
        b.scrollBottom = rows - 1
        setCursor(0, 0)
        markAllDirty()
    }
}
