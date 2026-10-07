// SheepVTRender — command marks (4.2 (4)).
//
// Return marks the cursor's row: that row holds the prompt and the command.
// The marks give the scrollback a structure — Previous/Next Command jump
// between them, Copy Last Output takes what lies between the last one and
// the cursor — and a hairline above each marked row shows where a command
// began. The mark lives on the `Row` object, so it rides through scrolling
// and reflow and is cleared only when the ring recycles the row.

import AppKit
import Testing

@testable import SheepVTRender
import SheepVT

@Suite struct CommandMarkTests {

    private func makeView(rows: Int = 6, scrollback: Int = 20) -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240), cols: 40, rows: rows, scrollback: scrollback)
    }

    /// Return marks; a paste, a focus report or a plain character does not.
    @Test func returnMarksTheCursorRowAndNothingElseDoes() {
        let view = makeView()
        view.feed("Switch# show ver")
        let line0 = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        #expect(view.terminal.commandLines().isEmpty)

        view.send([0x61])                                  // 'a'
        #expect(view.terminal.commandLines().isEmpty)
        view.send([0x0D], keystroke: false)                // a paste's CR
        #expect(view.terminal.commandLines().isEmpty)
        view.send([0x0D])                                  // Return
        #expect(view.terminal.commandLines() == [line0])
        view.send([0x0D])                                  // twice on one row: one mark
        #expect(view.terminal.commandLines() == [line0])

        // The device echoes CR LF and prints; the next command is a new mark.
        view.feed("\r\nCisco IOS XE\r\nSwitch# ")
        view.send([0x0D, 0x0A])                            // LNM form of Return
        #expect(view.terminal.commandLines() == [line0, line0 + 2])

        // Switched off: nothing is marked.
        view.commandMarksEnabled = false
        view.feed("\r\nSwitch# ")
        view.send([0x0D])
        #expect(view.terminal.commandLines() == [line0, line0 + 2])
    }

    /// The alternate screen (vim, less) is not history: Return there marks
    /// nothing, and the primary screen's marks are untouched by it.
    @Test func theAlternateScreenIsNeverMarked() {
        let view = makeView()
        view.feed("Switch# vim\r\n")
        view.send([0x0D])
        let marks = view.terminal.commandLines()
        view.feed("\u{1b}[?1049h")                         // enter alt screen
        #expect(view.terminal.isAlternate)
        view.send([0x0D])
        #expect(view.terminal.commandLines() == marks)
        view.feed("\u{1b}[?1049l")
        #expect(view.terminal.commandLines() == marks)
    }

    /// Marks follow their rows into the scrollback and go when the row does.
    /// (The view sizes its grid from its frame, so the ring is `rows + 4`
    /// for whatever `rows` the frame gave it — the test counts from there.)
    @Test func marksScrollWithTheirRowsAndFallOffWithThem() {
        let view = makeView(rows: 4, scrollback: 4)
        let ring = view.terminal.rows + 4
        view.feed("# first")
        view.send([0x0D])
        let first = view.terminal.commandLines()
        #expect(first.count == 1)
        for i in 0..<(view.terminal.rows + 1) { view.feed("\r\nline \(i)") }
        #expect(view.terminal.commandLines() == first)     // scrolled into history, still there
        #expect(view.terminal.buffer.row(line: first[0])?.commandMark == true)
        for i in 0..<ring { view.feed("\r\nmore \(i)") }    // the ring recycles the row
        #expect(view.terminal.commandLines().isEmpty)
        // …and the recycled row object itself carries no stale mark.
        for i in 0..<view.terminal.buffer.lines.count {
            #expect(view.terminal.buffer.lines.allocatedRow(at: i)?.commandMark != true)
        }
    }

    /// Previous / Next jump between marks, and only between marks.
    @Test func previousAndNextCommandMoveTheViewport() {
        let view = makeView(rows: 4, scrollback: 100)
        // Each command prints more than a screen, so every mark but the
        // newest sits above the top of the viewport.
        for n in 1...5 {
            view.feed("# cmd\(n)")
            view.send([0x0D])
            for i in 0..<(view.terminal.rows + 1) { view.feed("\r\nout \(n)-\(i)") }
            view.feed("\r\n")
        }
        let marks = view.terminal.commandLines()
        #expect(marks.count == 5)
        let b = view.terminal.buffer
        #expect(b.ydisp == b.ybase)                         // following the bottom

        #expect(view.scrollToPreviousCommand())
        #expect(b.lineNumber(ofViewportRow: 0) == marks[4])
        #expect(view.scrollToPreviousCommand())
        #expect(b.lineNumber(ofViewportRow: 0) == marks[3])
        #expect(view.scrollToNextCommand())
        #expect(b.lineNumber(ofViewportRow: 0) == marks[4])
        // Past the last mark: nothing to go to.
        #expect(!view.scrollToNextCommand())
        // All the way up, then no further.
        while view.scrollToPreviousCommand() {}
        #expect(b.lineNumber(ofViewportRow: 0) == marks[0])
        #expect(!view.scrollToPreviousCommand())
    }

    /// Copy Last Output: the lines between the last mark and the cursor,
    /// trailing blanks dropped, soft wraps joined.
    @Test func copyLastOutputTakesWhatTheLastCommandPrinted() {
        let view = makeView(rows: 6, scrollback: 100)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sheepvt.tests.commandmarks"))
        view.pasteboard = pasteboard
        #expect(!view.copyLastOutput())                     // no mark yet
        #expect(view.terminal.lastCommandOutput() == nil)

        view.feed("Switch# show clock")
        view.send([0x0D])
        #expect(view.terminal.lastCommandOutput() == nil)   // nothing printed yet
        view.feed("\r\n14:37:24.123 UTC Wed Oct 7 2026\r\n\r\nSwitch# ")
        #expect(view.terminal.lastCommandOutput() == "14:37:24.123 UTC Wed Oct 7 2026")
        #expect(view.copyLastOutput())
        #expect(pasteboard.string(forType: .string) == "14:37:24.123 UTC Wed Oct 7 2026")

        // A line longer than the screen wraps; the copy joins it back up.
        let long = String(repeating: "x", count: 50)
        view.feed("show run")
        view.send([0x0D])
        view.feed("\r\n\(long)\r\nend\r\nSwitch# ")
        #expect(view.terminal.lastCommandOutput() == "\(long)\nend")
    }

    /// A width change rewraps the history; the mark stays on its command.
    @Test func reflowKeepsTheMark() {
        let view = makeView(rows: 6, scrollback: 100)
        view.feed("Switch# show interfaces status | include connected")
        view.send([0x0D])
        view.feed("\r\nGi1/0/1 connected\r\nSwitch# ")
        #expect(view.terminal.commandLines().count == 1)
        view.terminal.resize(cols: 20, rows: 6)            // the command now wraps
        let marks = view.terminal.commandLines()
        #expect(marks.count == 1)
        #expect(view.terminal.buffer.row(line: marks[0])?.string().hasPrefix("Switch# show") == true)
        view.terminal.resize(cols: 80, rows: 6)
        #expect(view.terminal.commandLines().count == 1)
    }

    /// A command longer than the screen wraps; Return is pressed on the
    /// continuation row, but the mark belongs to the HEAD — and survives the
    /// widen that folds the continuation back into it.
    @Test func aWrappedCommandIsMarkedOnItsHeadAndSurvivesWidening() {
        let view = makeView(rows: 6, scrollback: 100)
        let cols = view.terminal.cols
        let command = "Switch# show " + String(repeating: "x", count: cols)   // > cols: wraps once
        view.feed(command)
        view.send([0x0D])
        let marks = view.terminal.commandLines()
        #expect(marks.count == 1)
        let head = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        #expect(marks == [head])
        #expect(view.terminal.buffer.row(line: head)?.string().hasPrefix("Switch# show") == true)
        view.feed("\r\nout\r\nSwitch# ")
        view.terminal.resize(cols: cols * 2 + 20, rows: 6)       // the line fits on one row now
        let after = view.terminal.commandLines()
        #expect(after.count == 1)
        #expect(view.terminal.buffer.row(line: after[0])?.string().hasPrefix("Switch# show") == true)
    }

    /// Blanks inside a wrapped output line are part of the line.
    @Test func copyLastOutputKeepsBlanksInsideAWrappedLine() {
        let view = makeView(rows: 6, scrollback: 100)
        let cols = view.terminal.cols
        view.feed("# cmd")
        view.send([0x0D])
        let first = "a" + String(repeating: " ", count: cols - 1)       // fills the row, ends in blanks
        view.feed("\r\n" + first + "b\r\n# ")
        #expect(view.terminal.lastCommandOutput() == first + "b")
    }

    /// Erasing the screen erases the commands on it: no hairline on a blank
    /// row, no stop for ⌘↓.
    @Test func erasingTheScreenDropsTheMarks() {
        let view = makeView()
        view.feed("# cmd")
        view.send([0x0D])
        #expect(view.terminal.commandLines().count == 1)
        view.feed("\u{1b}[2J")
        #expect(view.terminal.commandLines().isEmpty)
    }

    /// The hairline: a marked row has one more decoration than it had.
    @Test func aMarkedRowGetsAHairline() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("Switch# show ver")
        let line = harness.terminal.buffer.lineNumber(ofScreenRow: 0)
        let builder = RowBuilder(palette: harness.renderer.palette, metrics: harness.renderer.fontSet.metrics,
                                 glyphs: harness.renderer.context.glyphCache)
        let before = builder.build(row: harness.terminal.buffer.row(line: line), line: line, screenRow: 0,
                                   cols: harness.cols, overlay: plainOverlay(), cursor: nil)
        harness.terminal.markCommandLine()
        let after = builder.build(row: harness.terminal.buffer.row(line: line), line: line, screenRow: 0,
                                  cols: harness.cols, overlay: plainOverlay(), cursor: nil)
        #expect(after.decorations.count == before.decorations.count + 1)
        // …and the renderer repaints it: the mark bumped the row's generation.
        harness.render(plainOverlay())
        harness.terminal.buffer.row(line: line)?.commandMark = false
        harness.render(plainOverlay())
        #expect(harness.renderer.lastFrameStats.rowsRebuilt >= 1)
    }
}
