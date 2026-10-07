// SheepVTRender — selection echo (4.2 (4)).
//
// Select `Gi1/0/1` and every other `Gi1/0/1` on screen lights up quietly, so
// a port, an address or a MAC can be followed down a table without opening
// the find bar. The view derives a term from the selection (`echoTerm`), a
// second `SearchEngine` finds it, and the row builder tints the hits in the
// search colour at `echoAlpha` — under any real search tint.

import AppKit
import Testing

@testable import SheepVTRender
import SheepVT

@Suite struct SelectionEchoTests {

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240), cols: 40, rows: 6)
    }

    /// The term is the selected word — and nothing that is not a word.
    @Test func theEchoTermIsASingleLineWordOrNothing() {
        let view = makeView()
        view.feed("Gi1/0/1 up\r\nGi1/0/2 down\r\nGi1/0/1 again")
        let line0 = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        #expect(view.echoTerm == "")                                  // no selection

        view.selection.begin(at: Position(line: line0, col: 0))
        view.selection.extend(to: Position(line: line0, col: 6))
        #expect(view.echoTerm == "Gi1/0/1")

        // One character is not a word worth echoing.
        view.selection.begin(at: Position(line: line0, col: 0))
        view.selection.extend(to: Position(line: line0, col: 0))
        #expect(view.echoTerm == "")

        // Whitespace inside: a phrase, not a token.
        view.selection.begin(at: Position(line: line0, col: 0))
        view.selection.extend(to: Position(line: line0, col: 9))
        #expect(view.echoTerm == "")

        // Two lines: a dragged region, not a token.
        view.selection.begin(at: Position(line: line0, col: 0))
        view.selection.extend(to: Position(line: line0 + 1, col: 6))
        #expect(view.echoTerm == "")

        // Line and block modes never echo.
        view.selection.begin(at: Position(line: line0, col: 0), mode: .line)
        #expect(view.echoTerm == "")
        view.selection.clear()
        #expect(view.echoTerm == "")
    }

    /// The overlay carries the OTHER occurrences too (the selected one is
    /// among them — the selection tint lies over it), and only while the
    /// selection is a word.
    @Test func theOverlayCarriesTheEchoes() {
        let view = makeView()
        view.feed("Gi1/0/1 up\r\nGi1/0/2 down\r\nGi1/0/1 again")
        let line0 = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        #expect(view.makeOverlay().echoMatches.isEmpty)

        view.selection.begin(at: Position(line: line0, col: 0))
        view.selection.extend(to: Position(line: line0, col: 6))
        let echoes = view.makeOverlay().echoMatches
        #expect(echoes.count == 2)
        #expect(echoes.map(\.start.line).sorted() == [line0, line0 + 2])
        #expect(echoes.allSatisfy { $0.start.col == 0 && $0.end.col == 6 })

        // Case matters: the selection is the exact text.
        view.feed("\r\ngi1/0/1 lower")
        #expect(view.makeOverlay().echoMatches.count == 2)

        // The find bar's own search is untouched by the echo engine.
        #expect(view.search.term == "")
        view.selection.clear()
        #expect(view.makeOverlay().echoMatches.isEmpty)
    }

    /// The pixels: an echoed cell is tinted (quietly), a real search hit on
    /// the same cell is tinted more, and a cell outside both is the plain
    /// background.
    @Test func echoesAreTintedUnderSearchHits() throws {
        guard let harness = try makeHarness() else { return }
        harness.terminal.feed("foo bar foo")
        let line = harness.terminal.buffer.lineNumber(ofScreenRow: 0)
        let metrics = harness.renderer.fontSet.metrics
        let cellW = Int((metrics.width * harness.scale).rounded())
        let cellH = Int((metrics.height * harness.scale).rounded())
        // Sample the top-left corner of a cell, above any glyph ink.
        func corner(_ fb: Framebuffer, col: Int) -> UInt32 { fb.rgb(x: col * cellW + 1, y: 1) }
        _ = cellH

        harness.render(plainOverlay())
        let plain = harness.readback()
        let background = corner(plain, col: 3)

        var overlay = plainOverlay()
        overlay.echoMatches = [SearchMatch(start: Position(line: line, col: 8), end: Position(line: line, col: 10))]
        harness.render(overlay)
        let echoed = harness.readback()
        #expect(corner(echoed, col: 8) != background)           // the echo tint is there
        #expect(corner(echoed, col: 3) == background)           // and nowhere else

        overlay.searchMatches = overlay.echoMatches
        harness.render(overlay)
        let searched = harness.readback()
        #expect(corner(searched, col: 8) != corner(echoed, col: 8))   // the search tint lies over it

        // The row cache keys on the echoes: dropping them repaints the row.
        harness.render(FrameOverlay())
        _ = harness.readback()
        overlay = plainOverlay()
        harness.render(overlay)
        let cleared = harness.readback()
        #expect(corner(cleared, col: 8) == background)
    }
}
