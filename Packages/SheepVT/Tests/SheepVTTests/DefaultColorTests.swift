// SheepVT — the default colours: who owns them, and the way back.
//
// OSC 10/11/12 let a program move the terminal's default foreground,
// background and cursor colour; OSC 110/111/112 and RIS are how it hands them
// back. "Back" can only mean the host's theme — the user picked it — so the
// core keeps the theme's colour beside the one in effect. These tests pin the
// two layers apart: what a program moves, what the host owns, and what each
// reset restores.

import Testing
@testable import SheepVT

/// Captures what the terminal writes back, for the `?` queries.
private final class ReplySink: TerminalDelegate {
    var out: [UInt8] = []
    func send(_ terminal: Terminal, bytes: [UInt8]) { out += bytes }
    var text: String { String(decoding: out, as: UTF8.self) }
}

@Suite("default colours — OSC 10/11/12 and the way back") struct DefaultColorTests {

    /// The host's write is a theme: it sets the baseline as well as what is in
    /// effect, which is the whole reason a program can be given its colour back.
    @Test func theHostsWriteSetsBothTheBaselineAndWhatIsInEffect() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultBackground = 0x202020
        t.defaultForeground = 0xC0C0C0
        t.defaultCursorColor = 0xFF00FF
        #expect(t.hostBackground == 0x202020)
        #expect(t.hostForeground == 0xC0C0C0)
        #expect(t.hostCursorColor == 0xFF00FF)
        #expect(t.defaultBackground == 0x202020)
    }

    /// A program's OSC moves only what is in effect — the theme is remembered.
    @Test func aProgramsOscLeavesTheHostBaselineAlone() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultBackground = 0x202020
        t.feed("\u{1b}]11;#00ff00\u{07}")
        #expect(t.defaultBackground == 0x00FF00)
        #expect(t.hostBackground == 0x202020)
    }

    @Test func osc111RestoresTheHostBackground() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultBackground = 0x202020
        t.feed("\u{1b}]11;#00ff00\u{07}")
        let generation = t.defaultColorGeneration
        t.feed("\u{1b}]111\u{07}")
        #expect(t.defaultBackground == 0x202020)
        // The renderer follows the counter, not the values — a restore that
        // does not move it never reaches the pixels.
        #expect(t.defaultColorGeneration == generation + 1)
    }

    @Test func osc110And112RestoreTheHostForegroundAndCursor() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultForeground = 0xC0C0C0
        t.defaultCursorColor = 0x3366FF
        t.feed("\u{1b}]10;#ff0000\u{07}\u{1b}]12;#00ff00\u{07}")
        #expect(t.defaultForeground == 0xFF0000)
        #expect(t.defaultCursorColor == 0x00FF00)
        t.feed("\u{1b}]110\u{07}\u{1b}]112\u{07}")
        #expect(t.defaultForeground == 0xC0C0C0)
        #expect(t.defaultCursorColor == 0x3366FF)
    }

    /// A reset with nothing to undo is not a change: the counter must not move,
    /// or a chatty program would drop the renderer's row cache for nothing.
    @Test func aResetWithNoOverrideInForceIsNotAChange() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultBackground = 0x202020
        let generation = t.defaultColorGeneration
        t.feed("\u{1b}]111\u{07}\u{1b}]110\u{07}\u{1b}]112\u{07}")
        #expect(t.defaultColorGeneration == generation)
    }

    /// xterm ignores the payload on 110/111/112, and so do we — a program that
    /// writes `OSC 111;` (an empty argument) still means "put it back".
    @Test func aResetIgnoresItsPayload() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1b}]11;#00ff00\u{07}")
        t.feed("\u{1b}]111;\u{07}")
        #expect(t.defaultBackground == Terminal.themeBackground)
    }

    /// The user picks a new theme while `htop` holds its own background. The
    /// new theme wins immediately — the rest of the picture (ANSI palette,
    /// selection, cursor) changes with it, so half a theme would read as a bug
    /// — and the program's polite restore then lands on the theme the user is
    /// now looking at, not the one the tab was opened with.
    @Test func aThemeChangeWinsOverAProgramsOverrideAndBecomesTheNewBaseline() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultBackground = 0x202020                  // theme A
        t.feed("\u{1b}]11;#00ff00\u{07}")               // htop's own ground
        t.defaultBackground = 0xF5F5F5                  // theme B, picked live
        #expect(t.defaultBackground == 0xF5F5F5)        // the user sees theme B at once
        t.feed("\u{1b}]111\u{07}")                      // htop exits politely
        #expect(t.defaultBackground == 0xF5F5F5)        // …and theme B stays
        #expect(t.hostBackground == 0xF5F5F5)
    }

    /// RIS is power-on state, and the theme is what "power on" means here.
    @Test func risRestoresTheDefaultColoursAsWellAsThePalette() {
        let t = Terminal(cols: 10, rows: 2)
        t.defaultForeground = 0xC0C0C0
        t.defaultBackground = 0x202020
        t.defaultCursorColor = 0x3366FF
        t.feed("\u{1b}]10;#ff0000\u{07}\u{1b}]11;#00ff00\u{07}\u{1b}]12;#0000ff\u{07}")
        t.feed("\u{1b}]4;1;#123456\u{07}")
        let generation = t.defaultColorGeneration
        t.feed("\u{1b}c")
        #expect(t.defaultForeground == 0xC0C0C0)
        #expect(t.defaultBackground == 0x202020)
        #expect(t.defaultCursorColor == 0x3366FF)
        #expect(t.palette[1] == nil)
        #expect(t.defaultColorGeneration > generation)
    }

    // MARK: - queries

    /// A query answers what is in effect. A program that set its own scheme and
    /// then asks must be told what it is looking at, or it restores the wrong
    /// colour itself.
    @Test func queriesReportTheColourInEffectNotTheBaseline() {
        let sink = ReplySink()
        let t = Terminal(cols: 10, rows: 2, delegate: sink)
        t.defaultBackground = 0x202020
        t.feed("\u{1b}]11;#00ff00\u{07}")
        t.feed("\u{1b}]11;?\u{1b}\\")
        #expect(sink.text == "\u{1b}]11;rgb:0000/ffff/0000\u{1b}\\")
        sink.out.removeAll()
        // …and after the restore it reports the theme again.
        t.feed("\u{1b}]111\u{07}\u{1b}]11;?\u{1b}\\")
        #expect(sink.text == "\u{1b}]11;rgb:2020/2020/2020\u{1b}\\")
    }

    @Test func osc12SetsQueriesAndAnswersWithItsOwnNumber() {
        let sink = ReplySink()
        let t = Terminal(cols: 10, rows: 2, delegate: sink)
        t.feed("\u{1b}]12;#ff8800\u{07}")
        #expect(t.defaultCursorColor == 0xFF8800)
        t.feed("\u{1b}]12;?\u{1b}\\")
        #expect(sink.text == "\u{1b}]12;rgb:ffff/8888/0000\u{1b}\\")
    }

    /// `OSC 10 ; fg ; bg ; cursor` — one sequence, three slots, the way xterm
    /// walks them from whichever number started it.
    @Test func osc10WalksOnIntoTheBackgroundAndCursorSlots() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1b}]10;#111111;#222222;#333333\u{07}")
        #expect(t.defaultForeground == 0x111111)
        #expect(t.defaultBackground == 0x222222)
        #expect(t.defaultCursorColor == 0x333333)
        // Still only a program's move: the theme is untouched underneath.
        #expect(t.hostForeground == Terminal.themeForeground)
        t.feed("\u{1b}]110\u{07}\u{1b}]111\u{07}\u{1b}]112\u{07}")
        #expect(t.defaultForeground == Terminal.themeForeground)
        #expect(t.defaultBackground == Terminal.themeBackground)
        #expect(t.defaultCursorColor == Terminal.themeForeground)
    }

    /// The screen has to be repainted, not just the counter moved: the default
    /// colour is on every cell that never set one.
    @Test func aRestoreMarksTheWholeScreenDirty() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("\u{1b}]11;#00ff00\u{07}")
        t.clearDirty()
        t.feed("\u{1b}]111\u{07}")
        #expect(t.dirtyRows == 0...2)
    }
}
