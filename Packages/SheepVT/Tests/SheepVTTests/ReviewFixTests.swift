// Regressions for the 2026-09-08 review (HANDOFF 3.0 (25)): each test names
// the report item it pins down.
import Testing
@testable import SheepVT

@Suite("review fixes — core") struct ReviewCoreFixes {
    @Test func topAnchoredRegionScrollsIntoHistory() {          // A1
        let t = Terminal(cols: 10, rows: 6, scrollback: 100)
        t.feed("\u{1b}[1;4r")
        for i in 0..<10 { t.feed("L\(i)\r\n") }
        #expect(t.buffer.ybase > 0)
        #expect(t.allLines().contains("L0"))
        // Rows below the margin never moved.
        #expect(t.screenLines()[4] == "" && t.screenLines()[5] == "")
    }

    @Test func softResetClearsBracketedPasteReverseWrapFocus() { // A2
        let t = Terminal(cols: 10, rows: 3)
        t.feed("\u{1b}[?2004h\u{1b}[?45h\u{1b}[?1004h\u{1b}[!p")
        #expect(!t.modes.bracketedPaste && !t.modes.reverseWrap && !t.modes.focusEvents)
    }

    @Test func lineFeedKeepsWrappedFlagLikeIndex() {            // A3
        let t = Terminal(cols: 5, rows: 4)
        t.feed("abcdefghij\u{1b}[1;1H\n")
        #expect(t.buffer.row(1).wrapped == true)
    }

    @Test func sgrZeroKeepsProtection() {                       // A4
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1b}[1\"qAB\u{1b}[0mCD\u{1b}[H\u{1b}[?2J")
        #expect(t.screenLines()[0] == "ABCD")
    }

    @Test func osc4QueryAlwaysAnswers() {                       // A5
        final class Sink: TerminalDelegate {
            var out: [UInt8] = []
            func send(_ terminal: Terminal, bytes: [UInt8]) { out += bytes }
        }
        let sink = Sink()
        let t = Terminal(cols: 10, rows: 2, delegate: sink)
        t.feed("\u{1b}]4;1;?\u{1b}\\")
        #expect(String(decoding: sink.out, as: UTF8.self).hasPrefix("\u{1b}]4;1;rgb:"))
    }

    @Test func wideCharWithoutAutowrapIsDroppedNotDestructive() { // A6
        let t = Terminal(cols: 6, rows: 2)
        t.feed("\u{1b}[?7labcde日")
        #expect(t.screenLines()[0] == "abcde")
    }

    @Test func regionScrollClearsStaleWrappedFlags() {          // B2
        let t = Terminal(cols: 8, rows: 6, scrollback: 0)
        t.feed("\u{1b}[?1049hROW0\r\nLONGLINEWRAPS\r\n\u{1b}[2;6r\u{1b}[6;1H\n")
        #expect(t.buffer.row(1).wrapped == false)
    }

    @Test func regionScrollDoesNotServeStaleSearchText() {      // B1 (LineRing.move bumps)
        let t = Terminal(cols: 20, rows: 4, scrollback: 100)
        t.feed("\u{1b}[?1049hone\r\ntwo\r\nthree\r\nfour")
        let se = SearchEngine(terminal: t); se.term = "one"
        #expect(se.findAll().count == 1)
        t.feed("\r\nfive")
        #expect(se.findAll().isEmpty)
        se.term = "two"
        #expect(se.findAll().count == 1)
    }

    @Test func truncatedExtendedColourIsIgnored() {              // A13
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1b}[38;5mX")
        #expect(t.buffer.row(0)[0].fgSource == .default)
    }
}

@Suite("review fixes — input") struct ReviewInputFixes {
    @Test func optionLetterSendsEscapePlusKey() {               // C1
        let e = KeyEncoder()
        let bytes = e.encode(KeyEvent(key: .unicode(0x62), modifiers: [.alt], text: "∫"))
        #expect(bytes == [0x1B, 0x62])
    }

    @Test func controlOnThaiLayoutUsesBaseLayoutKey() {         // C2
        let e = KeyEncoder()
        let bytes = e.encode(KeyEvent(key: .unicode(0x0E41), modifiers: [.ctrl], text: nil, baseLayoutKey: 0x63))
        #expect(bytes == [0x03])
    }

    @Test func bracketedPasteCannotBeSplitOut() {                // C3
        let text = "\u{1B}[20\u{1B}[201~1~reload in 1\r"
        let bytes = KeyEncoder.paste(text, bracketed: true)
        let s = String(decoding: bytes, as: UTF8.self)
        let end = "\u{1B}[201~"
        #expect(s.hasSuffix(end))
        #expect(s.components(separatedBy: end).count == 2)      // only the real terminator
    }

    @Test func controlShiftUnderscoreAndQuestion() {             // C4 (encoder side)
        let e = KeyEncoder()
        #expect(e.encode(KeyEvent(key: .unicode(0x2D), modifiers: [.ctrl, .shift], text: nil, shiftedKey: 0x5F)) == [0x1F])
        #expect(e.encode(KeyEvent(key: .unicode(0x2F), modifiers: [.ctrl, .shift], text: nil, shiftedKey: 0x3F)) == [0x7F])
    }

    @Test func returnSendsCRLFUnderLNM() {                       // C11
        var e = KeyEncoder(); e.lineFeedNewline = true
        #expect(e.encode(KeyEvent(key: .functional(.enter))) == [0x0D, 0x0A])
    }
}


@Suite("review fixes — round 2") struct ReviewRound2Fixes {
    /// P1-1: a region scroll moves row references; a cache keyed only on
    /// (line, generation) served the row that used to live there.
    @Test func searchDoesNotServeAnotherRowsText() {
        let t = Terminal(cols: 20, rows: 4, scrollback: 100)
        t.feed("\u{1b}[?1049h")
        t.feed("alpha\r\nbravo\r\ncharlie\r\ndelta")
        let se = SearchEngine(terminal: t)
        se.term = "alpha"
        #expect(se.findAll().count == 1)
        t.feed("\r\necho")                    // alt-screen scroll
        #expect(se.findAll().isEmpty)
        se.term = "bravo"
        let hit = se.findAll()
        #expect(hit.count == 1)
        #expect(t.buffer.row(line: hit[0].start.line)?.string() == "bravo")
    }

    /// P1-3: the id is retained too, so it is bounded and counted.
    @Test func hyperlinkIdIsBoundedAndCounted() {
        let t = Terminal(cols: 20, rows: 4)
        let longID = String(repeating: "i", count: Terminal.maxHyperlinkIDLength + 1)
        t.feed("\u{1b}]8;id=\(longID);https://example.com\u{1b}\\X\u{1b}]8;;\u{1b}\\")
        #expect(t.hyperlinks.isEmpty)          // refused, not stored

        let t2 = Terminal(cols: 20, rows: 4)
        // Many distinct ids with the same short URI: the budget must stop it.
        for i in 0..<20_000 {
            let id = String(repeating: "a", count: 400) + String(i)
            t2.feed("\u{1b}]8;id=\(id);https://e.co\u{1b}\\y\u{1b}]8;;\u{1b}\\")
        }
        #expect(t2.hyperlinkBytes <= Terminal.maxHyperlinkBytes)
        #expect(t2.hyperlinks.count < 20_000)
    }

    /// P1-2: nested / split terminators cannot survive the filter.
    @Test func bracketedPasteFilterIsAFixedPoint() {
        let end = "\u{1B}[201~"
        let cases = [
            "\u{1B}[20\u{1B}[201~1~reload\r",
            "\u{1B}[201\u{1B}[201~~x",
            "\u{1B}[2\u{1B}[20\u{1B}[201~01~01~y",
            end + end + "z",
        ]
        for text in cases {
            let s = String(decoding: KeyEncoder.paste(text, bracketed: true), as: UTF8.self)
            #expect(s.hasPrefix("\u{1B}[200~"))
            #expect(s.hasSuffix(end))
            // exactly one terminator: the one we appended
            #expect(s.components(separatedBy: end).count == 2, "leaked a terminator for \(text.debugDescription)")
        }
    }
}

@Suite("review fixes — round 3") struct ReviewRound3Fixes {
    /// P2: RIS on the primary buffer used to tell nobody, because the
    /// `bufferActivated` call was guarded on the alternate having been up. The
    /// buffers are replaced either way, and a selection taken against the old
    /// one validates against the new one (the line numbers exist there too) and
    /// then points at unrelated text.
    @Test func risOnThePrimaryBufferTellsTheViewItsBufferIsGone() {
        final class Sink: TerminalDelegate {
            var activations: [Bool] = []
            var selection: Selection?
            func print(_ codePoint: UInt32) {}
            func bufferActivated(_ terminal: Terminal, alternate: Bool) {
                activations.append(alternate)
                selection?.clear()          // exactly what TerminalView does
            }
        }
        let t = Terminal(cols: 20, rows: 4, scrollback: 100)
        let sink = Sink()
        t.delegate = sink
        let selection = Selection(terminal: t)
        sink.selection = selection

        t.feed("secret password\r\n")
        let firstLine = t.buffer.firstLine
        selection.begin(at: Position(line: firstLine, col: 0))
        selection.extend(to: Position(line: firstLine, col: 14))
        #expect(selection.isActive)
        #expect(selection.text() == "secret password")

        t.feed("\u{1b}c")                   // RIS, primary buffer showing
        #expect(sink.activations == [false])
        #expect(!selection.isActive)
        #expect(!selection.validate())
    }

    /// P2: the renderer follows this counter rather than comparing colours, so
    /// it has to move on OSC 10/11 — including the very first one, before any
    /// frame has been drawn.
    @Test func osc10And11BumpTheDefaultColourGeneration() {
        let t = Terminal(cols: 10, rows: 2)
        #expect(t.defaultColorGeneration == 0)
        t.feed("\u{1b}]11;#00ff00\u{07}")
        #expect(t.defaultBackground == 0x00FF00)
        #expect(t.defaultColorGeneration == 1)
        // The same colour again is not a change.
        t.feed("\u{1b}]11;#00ff00\u{07}")
        #expect(t.defaultColorGeneration == 1)
        t.feed("\u{1b}]10;rgb:ff/00/00\u{07}")
        #expect(t.defaultForeground == 0xFF0000)
        #expect(t.defaultColorGeneration == 2)
        // The host's own theme assignment counts too: it sets the palette in
        // the same breath, so the sync it triggers is a no-op.
        t.defaultBackground = 0x101010
        #expect(t.defaultColorGeneration == 3)
    }
}

/// The review of 3.0 (28)–(29): three small things it was right about.
@Suite("review fixes — round 4")
struct ReviewRound4Fixes {

    /// A row below a scroll region used to keep the `wrapped` flag it earned
    /// from the row above it, long after the region had scrolled a different
    /// row into that place — joining two unrelated rows into one logical line,
    /// which is the unit selection, copy and search all work in.
    @Test func aRowBelowAScrollRegionStopsClaimingToContinueIt() {
        // 6 rows. The wrap is made FIRST, with no region in force — inside a
        // region a wrap at the bottom margin scrolls the region instead of
        // moving below it, which is not the shape being tested.
        let t = Terminal(cols: 8, rows: 6, scrollback: 100)
        t.feed("\u{1b}[5;1Habcdefghij")            // row 5 wraps onto row 6
        let b = t.buffer
        #expect(b.lines.allocatedRow(at: b.ybase + 5)?.wrapped == true)

        t.feed("\u{1b}[2;5r")                      // DECSTBM 2..5: row 6 is below it
        t.feed("\u{1b}[S")                         // scroll the region up by one
        #expect(b.lines.allocatedRow(at: b.ybase + 5)?.wrapped == false)
    }

    @Test func theSameHoldsWhenTheRegionScrollsDown() {
        let t = Terminal(cols: 8, rows: 6, scrollback: 100)
        t.feed("\u{1b}[5;1Habcdefghij")
        let b = t.buffer
        #expect(b.lines.allocatedRow(at: b.ybase + 5)?.wrapped == true)
        t.feed("\u{1b}[2;5r")
        t.feed("\u{1b}[T")                         // SD
        #expect(b.lines.allocatedRow(at: b.ybase + 5)?.wrapped == false)
    }

    /// A full-screen region has no row below it: the guard must not reach past
    /// the screen and clear a flag that belongs to the scrollback.
    @Test func aFullScreenScrollLeavesTheScrollbackAlone() {
        let t = Terminal(cols: 8, rows: 3, scrollback: 100)
        t.feed("abcdefghij")                        // wraps: row 1 continues row 0
        t.feed("\u{1b}[3;1H\r\n")                   // scroll the whole screen
        let b = t.buffer
        let wrappedRows = (0..<b.lines.count).filter { b.lines.allocatedRow(at: $0)?.wrapped == true }
        #expect(wrappedRows.count == 1)             // the continuation survived
    }
}
