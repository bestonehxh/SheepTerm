// SheepVTRender — view, key mapping and find-bar tests.
//
// No window is ever created: a `TerminalView` built from a frame is enough to
// exercise the geometry, the selection, the clipboard and the delegate
// plumbing, and `NSEvent.keyEvent(with:…)` gives the key mapping real events
// without a key window. The tests never touch the user's pasteboard — every
// clipboard test injects a private `NSPasteboard`.

import AppKit
import Testing
@testable import SheepVTRender
import SheepVT

// MARK: - helpers

@MainActor
private func makeEvent(_ keyCode: UInt16,
                       characters: String = "",
                       ignoring: String? = nil,
                       flags: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .keyDown) -> NSEvent {
    NSEvent.keyEvent(with: type,
                     location: .zero,
                     modifierFlags: flags,
                     timestamp: 0,
                     windowNumber: 0,
                     context: nil,
                     characters: characters,
                     charactersIgnoringModifiers: ignoring ?? characters,
                     isARepeat: false,
                     keyCode: keyCode)!
}

@MainActor
private func makeMouseEvent(_ type: NSEvent.EventType,
                            at location: CGPoint,
                            flags: NSEvent.ModifierFlags = [],
                            clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type,
                       location: location,
                       modifierFlags: flags,
                       timestamp: 0,
                       windowNumber: 0,
                       context: nil,
                       eventNumber: 0,
                       clickCount: clickCount,
                       pressure: 1)!
}

private func functionKeyString(_ value: Int) -> String {
    String(UnicodeScalar(UInt32(value))!)
}

@MainActor
private final class RecordingDelegate: TerminalViewDelegate {
    var sent: [[UInt8]] = []
    var sizes: [(cols: Int, rows: Int)] = []
    var titles: [String] = []
    var scrolls = 0
    var bells = 0
    var links: [String] = []
    var allowPaste = true

    var sentBytes: [UInt8] { sent.flatMap { $0 } }

    func send(_ view: TerminalView, bytes: [UInt8]) { sent.append(bytes) }
    func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) { sizes.append((cols, rows)) }
    func titleChanged(_ view: TerminalView, title: String) { titles.append(title) }
    func scrolled(_ view: TerminalView) { scrolls += 1 }
    func bell(_ view: TerminalView) { bells += 1 }
    func openLink(_ view: TerminalView, url: String) { links.append(url) }
    func shouldPaste(_ view: TerminalView, text: String) -> Bool { allowPaste }
}

@MainActor
private func makeView(width: CGFloat = 800, height: CGFloat = 480) -> TerminalView {
    TerminalView(frame: CGRect(x: 0, y: 0, width: width, height: height))
}

private func privateBoard(_ name: String) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("SheepVTTests.\(name)"))
    board.clearContents()
    return board
}

// MARK: - KeyMapping

@MainActor
@Suite struct KeyMappingTests {

    @Test func arrowsAreFunctionalKeys() {
        let table: [(UInt16, Int, FunctionalKey, String)] = [
            (126, NSUpArrowFunctionKey, .up, "\u{1b}[A"),
            (125, NSDownArrowFunctionKey, .down, "\u{1b}[B"),
            (124, NSRightArrowFunctionKey, .right, "\u{1b}[C"),
            (123, NSLeftArrowFunctionKey, .left, "\u{1b}[D"),
        ]
        for (code, scalar, expected, sequence) in table {
            let event = makeEvent(code, characters: functionKeyString(scalar),
                                  flags: [.function, .numericPad])
            let key = KeyMapping.keyEvent(from: event)
            #expect(key.key == .functional(expected))
            // A private-use function scalar is never "text".
            #expect(key.text == nil)
            let bytes = KeyEncoder().encode(key)
            #expect(bytes.map { String(decoding: $0, as: UTF8.self) } == sequence)
        }
    }

    @Test func editingAndNavigationKeys() {
        let table: [(UInt16, FunctionalKey)] = [
            (36, .enter), (48, .tab), (51, .backspace), (53, .escape),
            (115, .home), (116, .pageUp), (117, .delete), (119, .end), (121, .pageDown),
        ]
        for (code, expected) in table {
            let key = KeyMapping.keyEvent(from: makeEvent(code, characters: ""))
            #expect(key.key == .functional(expected), "keyCode \(code)")
        }
    }

    @Test func functionKeysF1ThroughF20() {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                               103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let expected: [FunctionalKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
                                         .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
        for (code, key) in zip(codes, expected) {
            let event = makeEvent(code, characters: functionKeyString(NSF1FunctionKey), flags: [.function])
            #expect(KeyMapping.keyEvent(from: event).key == .functional(key), "keyCode \(code)")
        }
        // F1 encodes as SS3 P, F5 as CSI 15~ — the two legacy blocks.
        let f1 = KeyMapping.keyEvent(from: makeEvent(122, characters: functionKeyString(NSF1FunctionKey)))
        #expect(KeyEncoder().encode(f1).map { String(decoding: $0, as: UTF8.self) } == "\u{1b}OP")
        let f5 = KeyMapping.keyEvent(from: makeEvent(96, characters: functionKeyString(NSF5FunctionKey)))
        #expect(KeyEncoder().encode(f5).map { String(decoding: $0, as: UTF8.self) } == "\u{1b}[15~")
    }

    @Test func keypadKeysCarryTheirText() {
        let five = KeyMapping.keyEvent(from: makeEvent(87, characters: "5", flags: [.numericPad]))
        #expect(five.key == .functional(.keypad5))
        #expect(five.text == "5")
        #expect(five.modifiers.contains(.numLock))
        #expect(KeyEncoder().encode(five).map { String(decoding: $0, as: UTF8.self) } == "5")

        var app = KeyEncoder()
        app.applicationKeypad = true
        #expect(app.encode(five).map { String(decoding: $0, as: UTF8.self) } == "\u{1b}Ou")

        let enter = KeyMapping.keyEvent(from: makeEvent(76, characters: "\r", flags: [.numericPad]))
        #expect(enter.key == .functional(.keypadEnter))
        #expect(enter.text == nil)          // CR is a control byte, not text
    }

    @Test func deadKeyOptionEProducesNoText() {
        // ⌥e on a US layout: AppKit reports an empty `characters` because the
        // key started a dead-key sequence.
        let event = makeEvent(14, characters: "", ignoring: "e", flags: [.option])
        let key = KeyMapping.keyEvent(from: event)
        #expect(key.key == .unicode(UInt32(UnicodeScalar("e").value)))
        #expect(key.text == nil)
        #expect(key.modifiers.contains(.alt))
    }

    @Test func commandChordsAreTheAppsToHandle() {
        let event = makeEvent(8, characters: "c", ignoring: "c", flags: [.command])
        let key = KeyMapping.keyEvent(from: event)
        #expect(key.modifiers.contains(.super))
        // The encoder declines, so ⌘C reaches AppKit's menu handling.
        #expect(KeyEncoder().encode(key) == nil)
    }

    @Test func controlChordsMapToControlBytes() {
        let event = makeEvent(0, characters: "\u{01}", ignoring: "a", flags: [.control])
        let key = KeyMapping.keyEvent(from: event)
        #expect(key.key == .unicode(UInt32(UnicodeScalar("a").value)))
        #expect(key.modifiers.contains(.ctrl))
        #expect(KeyEncoder().encode(key) == [0x01])
    }

    @Test func shiftKeepsBothTheBaseAndTheShiftedKey() {
        // ⇧2 on a US layout: charactersIgnoringModifiers is already "@".
        let event = makeEvent(19, characters: "@", ignoring: "@", flags: [.shift])
        let key = KeyMapping.keyEvent(from: event)
        #expect(key.key == .unicode(UInt32(UnicodeScalar("2").value)))
        #expect(key.shiftedKey == UInt32(UnicodeScalar("@").value))
        #expect(KeyEncoder().encode(key) == Array("@".utf8))
    }

    @Test func baseLayoutKeyComesFromTheUSTable() {
        // A layout where keyCode 12 types "ๆ" (Thai): the key is what the user
        // typed, `baseLayoutKey` is the US "q" kitty asks for.
        let event = makeEvent(12, characters: "ๆ", ignoring: "ๆ")
        let key = KeyMapping.keyEvent(from: event)
        #expect(key.key == .unicode("ๆ".unicodeScalars.first!.value))
        #expect(key.baseLayoutKey == UInt32(UnicodeScalar("q").value))
    }

    @Test func modifierTable() {
        let all = KeyMapping.modifiers(from: [.shift, .option, .control, .command, .capsLock])
        #expect(all.contains(.shift) && all.contains(.alt) && all.contains(.ctrl))
        #expect(all.contains(.super) && all.contains(.capsLock))
        #expect(!all.contains(.numLock))
        #expect(KeyMapping.modifiers(from: []) == [])
    }

    @Test func printableTextRejectsControlsAndFunctionScalars() {
        #expect(KeyMapping.printableText(of: makeEvent(0, characters: "a")) == "a")
        #expect(KeyMapping.printableText(of: makeEvent(36, characters: "\r")) == nil)
        #expect(KeyMapping.printableText(of: makeEvent(51, characters: "\u{7f}")) == nil)
        #expect(KeyMapping.printableText(of: makeEvent(126, characters: functionKeyString(NSUpArrowFunctionKey))) == nil)
        #expect(KeyMapping.printableText(of: makeEvent(14, characters: "")) == nil)
    }

    @Test func modifierKeysAreNamedByKeyCode() {
        #expect(KeyMapping.modifierKey(from: 56) == .leftShift)
        #expect(KeyMapping.modifierKey(from: 59) == .leftControl)
        #expect(KeyMapping.modifierKey(from: 55) == .leftSuper)
        #expect(KeyMapping.modifierKey(from: 0) == nil)
    }
}

// MARK: - The view

@MainActor
@Suite struct TerminalViewTests {

    @Test func gridFollowsTheFrameAndTheFont() {
        let view = makeView(width: 800, height: 480)
        #expect(view.cols == Int(floor(800 / view.cellWidth)))
        #expect(view.rows == Int(floor(480 / view.cellHeight)))
        #expect(view.cols == view.terminal.cols)
        #expect(view.rows == view.terminal.rows)
        #expect(view.cols > 20)

        let wide = makeView(width: 1600, height: 480)
        #expect(abs(wide.cols - view.cols * 2) <= 1)
    }

    @Test func aTinyFrameStillMakesALegalGrid() {
        let view = makeView(width: 1, height: 1)
        #expect(view.cols >= Terminal.minCols)
        #expect(view.rows >= Terminal.minRows)
    }

    @Test func sizeChangedFiresOnlyWhenTheGridChanges() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        let cols = view.cols, rows = view.rows

        // Under one cell of growth: same grid, and the pty must not hear about
        // it (every shell answers a winsize change with a fresh prompt).
        view.setFrameSize(NSSize(width: 800 + view.cellWidth / 3, height: 480))
        #expect(delegate.sizes.isEmpty)
        #expect(view.cols == cols && view.rows == rows)

        view.setFrameSize(NSSize(width: 400, height: 240))
        #expect(delegate.sizes.count == 1)
        #expect(delegate.sizes.last?.cols == view.cols)
        #expect(delegate.sizes.last?.rows == view.rows)
        #expect(view.cols < cols && view.rows < rows)
    }

    @Test func aFontChangeThatKeepsTheGridDoesNotResize() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        // Same size, same metrics: the grid is unchanged.
        #expect(delegate.sizes.isEmpty)
    }

    @Test func constructsWithoutAMetalDevice() {
        TerminalView.forceDisableMetal = true
        defer { TerminalView.forceDisableMetal = false }
        let view = makeView()
        #expect(view.renderer == nil)
        // Everything that is not painting still works.
        view.feed("hello")
        #expect(view.terminal.screenLines().first == "hello")
        view.setNeedsFrame()
        view.renderFrame()          // must not crash without a renderer
        #expect(view.cols > 0)
    }

    @Test func feedAndSelection() {
        let view = makeView()
        view.feed("hello world")
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        #expect(!view.hasSelection)
        view.selection.begin(at: Position(line: line, col: 0))
        view.selection.extend(to: Position(line: line, col: 4))
        #expect(view.hasSelection)
        #expect(view.selectedText == "hello")
        view.selection.begin(at: Position(line: line, col: 6), mode: .word)
        #expect(view.selectedText == "world")
    }

    @Test func hitTestMapsPointsToCellsAndClamps() {
        let view = makeView()
        view.feed("abcdef")
        let top = view.terminal.buffer.lineNumber(ofViewportRow: 0)
        let hit = view.hitTest(point: CGPoint(x: view.cellWidth * 2.5, y: view.cellHeight * 1.5))
        #expect(hit.col == 2)
        #expect(hit.line == view.terminal.buffer.lineNumber(ofViewportRow: 1))

        #expect(view.hitTest(point: CGPoint(x: -50, y: -50)) == Position(line: top, col: 0))
        let far = view.hitTest(point: CGPoint(x: 100_000, y: 100_000))
        #expect(far.col == view.cols - 1)
        #expect(far.line == view.terminal.buffer.lineNumber(ofViewportRow: view.rows - 1))
    }

    @Test func copyPutsTheSelectionOnTheInjectedPasteboard() {
        let view = makeView()
        view.pasteboard = privateBoard("copy")
        view.feed("interface up")
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        view.selection.begin(at: Position(line: line, col: 0))
        view.selection.extend(to: Position(line: line, col: 8))
        view.copy(nil)
        #expect(view.pasteboard.string(forType: .string) == "interface")
        #expect(view.validateUserInterfaceItem(NSMenuItem(title: "Copy",
                                                          action: #selector(TerminalView.copy(_:)),
                                                          keyEquivalent: "")))
    }

    @Test func pasteGoesThroughTheHostsVeto() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        let board = privateBoard("paste")
        board.setString("show version", forType: .string)
        view.pasteboard = board

        delegate.allowPaste = false
        view.paste(nil)
        #expect(delegate.sent.isEmpty)

        delegate.allowPaste = true
        view.paste(nil)
        #expect(delegate.sentBytes == Array("show version".utf8))

        // Bracketed paste wraps the same text.
        delegate.sent.removeAll()
        view.feed("\u{1b}[?2004h")
        view.paste(nil)
        let out = String(decoding: delegate.sentBytes, as: UTF8.self)
        #expect(out == "\u{1b}[200~show version\u{1b}[201~")
    }

    @Test func findMovesTheCurrentMatch() {
        let view = makeView()
        view.feed("alpha one\r\nbeta two\r\nalpha three\r\n")
        view.search.term = "alpha"
        #expect(view.currentMatch == nil)

        let next = NSMenuItem(title: "Next", action: nil, keyEquivalent: "")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        view.performTextFinderAction(next)
        let first = view.currentMatch
        #expect(first != nil)
        view.performTextFinderAction(next)
        let second = view.currentMatch
        #expect(second != nil)
        #expect(first != second)
        #expect(second!.start.line > first!.start.line)

        let previous = NSMenuItem(title: "Previous", action: nil, keyEquivalent: "")
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        view.performTextFinderAction(previous)
        #expect(view.currentMatch == first)
    }

    @Test func aCatastrophicRegexDoesNotBlockTheFindBar() {
        // The path the user actually takes: type into the find bar with `.*`
        // on. `findBarChanged → findNext → findAll → text.matches(of:)` used to
        // run the pattern on the main thread, and `(a+)+b` over twenty-odd `a`s
        // never comes back — the app was simply gone.
        let view = makeView()
        view.feed(String(repeating: "a", count: 24))
        view.showFind()
        let bar = view.findBar!
        bar.debounceInterval = 0
        bar.options = SearchOptions(regex: true)

        let clock = ContinuousClock()
        let blocked = clock.measure { bar.searchText = "(a+)+b" }
        // Not "it gave up in time" any more — it ANSWERED. `LinearRegex` has no
        // backtracking to explode, so this is an ordinary search that finds
        // nothing, and there is no "too slow" state left to report.
        #expect(blocked < .milliseconds(100))
        #expect(view.search.regexProblem == nil)
        #expect(view.currentMatch == nil)
        #expect(bar.statusText == "not found")

        let after = clock.measure { bar.searchText = "a+" }
        #expect(after < .seconds(1))
        #expect(bar.statusText == "1 of 1")
        #expect(view.currentMatch != nil)
    }

    @Test func useSelectionForFindSeedsTheTerm() {
        let view = makeView()
        view.feed("GigabitEthernet1/0/1 is up")
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        view.selection.begin(at: Position(line: line, col: 21), mode: .word)
        #expect(view.selectedText == "is")
        view.useSelectionForFind()
        #expect(view.search.term == "is")
        #expect(view.findBar?.isHidden == false)
        #expect(view.findBar?.searchText == "is")
    }

    @Test func showFindDoesNotSeedATermThatSpansLines() {
        // ⌘F over a selection seeds the term from it — unless the selection
        // spans lines, because such a term matches nothing. The test is
        // `isNewline`, not `contains("\n")`: CRLF is ONE Character and equals
        // neither "\n" nor "\r", and so are the separators a device can print
        // into a cell (U+2028, U+0085, VT, FF).
        //
        // (⌘E / `useSelectionForFind` is the other path and takes the
        // selection as given — see `useSelectionForFindSeedsTheTerm`.)
        let view = makeView()
        view.feed("alpha\u{2028}beta")
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        view.selection.begin(at: Position(line: line, col: 0))
        view.selection.extend(to: Position(line: line, col: 9))
        let selected = view.selectedText
        #expect(selected.contains { $0.isNewline })
        #expect(!selected.contains("\n"))        // what the old test asked
        view.showFind()
        #expect(view.findBar?.isHidden == false)  // the bar opens…
        #expect(view.findBar?.searchText == "")   // …with no term seeded
        // …and an ordinary two-row selection is still refused (plain LF).
        let view2 = makeView()
        view2.feed("first line\r\nsecond line")
        let top = view2.terminal.buffer.lineNumber(ofScreenRow: 0)
        view2.selection.begin(at: Position(line: top, col: 0))
        view2.selection.extend(to: Position(line: top + 1, col: 5))
        #expect(view2.selectedText.contains { $0.isNewline })
        view2.showFind()
        #expect(view2.findBar?.searchText == "")
    }

    @Test func scrollingMovesTheViewportAndTellsTheHost() {
        let view = makeView(width: 400, height: 120)
        let delegate = RecordingDelegate()
        view.delegate = delegate
        for i in 0..<200 { view.feed("line \(i)\r\n") }
        let buffer = view.terminal.buffer
        #expect(buffer.ybase > 0)
        #expect(buffer.ydisp == buffer.ybase)

        delegate.scrolls = 0
        view.scrollViewport(by: -10)
        #expect(buffer.ydisp == buffer.ybase - 10)
        #expect(delegate.scrolls == 1)

        view.scrollToBottom()
        #expect(buffer.ydisp == buffer.ybase)
        #expect(delegate.scrolls == 2)
    }

    @Test func clearScrollbackDropsHistoryAndTheSelection() {
        let view = makeView(width: 400, height: 120)
        for i in 0..<200 { view.feed("line \(i)\r\n") }
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        view.selection.begin(at: Position(line: line, col: 0))
        view.selection.extend(to: Position(line: line, col: 3))
        #expect(view.hasSelection)
        #expect(view.terminal.buffer.ybase > 0)

        view.clearScrollback()
        #expect(view.terminal.buffer.ybase == 0)
        #expect(view.terminal.buffer.ydisp == 0)
        #expect(!view.hasSelection)
    }

    @Test func terminalRepliesReachTheHost() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.feed("\u{1b}[c")                     // primary device attributes
        #expect(delegate.sent.count == 1)
        #expect(delegate.sentBytes.starts(with: [0x1b, 0x5b, 0x3f]))
    }

    @Test func titleAndBellAndDirectoryReachTheHost() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.feed("\u{1b}]0;core-sw-01\u{7}")
        #expect(delegate.titles == ["core-sw-01"])
        view.feed("\u{7}")
        #expect(delegate.bells == 1)
    }

    @Test func osc52WritesToTheInjectedPasteboard() {
        let view = makeView()
        view.pasteboard = privateBoard("osc52")
        // OSC 52 ; c ; base64("hello") BEL
        view.feed("\u{1b}]52;c;aGVsbG8=\u{7}")
        #expect(view.pasteboard.string(forType: .string) == "hello")
        // Reading is always refused: a program must not be able to read the
        // user's clipboard.
        #expect(view.getClipboard(view.terminal, selection: "c") == nil)
    }

    @Test func aBufferSwitchDropsSelectionAndSearch() {
        let view = makeView()
        view.feed("primary text")
        let line = view.terminal.buffer.lineNumber(ofScreenRow: 0)
        view.selection.begin(at: Position(line: line, col: 0))
        view.selection.extend(to: Position(line: line, col: 6))
        view.search.term = "primary"
        view.findNext()
        #expect(view.hasSelection)
        #expect(view.currentMatch != nil)

        view.feed("\u{1b}[?1049h")                 // to the alternate screen
        #expect(view.terminal.isAlternate)
        #expect(!view.hasSelection)
        #expect(view.currentMatch == nil)
    }

    @Test func synchronizedOutputHoldsFrames() {
        let view = makeView()
        #expect(view.syncHoldUntil == 0)
        view.feed("\u{1b}[?2026h")
        #expect(view.syncHoldUntil > CACurrentMediaTime())
        #expect(view.syncHoldUntil <= CACurrentMediaTime() + TerminalView.synchronizedOutputHold)
        view.feed("\u{1b}[?2026l")
        #expect(view.syncHoldUntil == 0)
    }

    @Test func keyDownEncodesAndSnapsToTheBottom() {
        let view = makeView(width: 400, height: 120)
        let delegate = RecordingDelegate()
        view.delegate = delegate
        for i in 0..<100 { view.feed("line \(i)\r\n") }
        view.scrollViewport(by: -20)
        #expect(view.terminal.buffer.ydisp < view.terminal.buffer.ybase)

        delegate.sent.removeAll()
        view.keyDown(with: makeEvent(0, characters: "a", ignoring: "a"))
        #expect(delegate.sentBytes == Array("a".utf8))
        // Typing snaps the viewport back to the live screen.
        #expect(view.terminal.buffer.ydisp == view.terminal.buffer.ybase)

        // An arrow goes through the encoder, in the mode the program asked for.
        delegate.sent.removeAll()
        view.feed("\u{1b}[?1h")                    // DECCKM
        view.keyDown(with: makeEvent(126, characters: functionKeyString(NSUpArrowFunctionKey),
                                     flags: [.function, .numericPad]))
        #expect(String(decoding: delegate.sentBytes, as: UTF8.self) == "\u{1b}OA")
    }

    @Test func markedTextIsTrackedAndCommitted() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        #expect(!view.hasMarkedText())
        view.setMarkedText("ก", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange().length == 1)
        #expect(delegate.sent.isEmpty)             // a preedit is not typed yet

        view.insertText("กา", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(delegate.sentBytes == Array("กา".utf8))
    }

    @Test func doCommandBridgesTheKeysAppKitClaims() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(delegate.sentBytes == [0x0d])
        delegate.sent.removeAll()
        view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(String(decoding: delegate.sentBytes, as: UTF8.self) == "\u{1b}[Z")
        delegate.sent.removeAll()
        // Nothing a terminal can express: dropped, not beeped at.
        view.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
        #expect(delegate.sent.isEmpty)
    }

    @Test func mouseReportingTakesOverTheGesture() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.feed("\u{1b}[?1000h\u{1b}[?1006h")    // normal tracking, SGR
        let point = CGPoint(x: view.cellWidth * 3.5, y: view.cellHeight * 2.5)
        let event = NSEvent.mouseEvent(with: .leftMouseDown,
                                       location: .zero,
                                       modifierFlags: [],
                                       timestamp: 0,
                                       windowNumber: 0,
                                       context: nil,
                                       eventNumber: 0,
                                       clickCount: 1,
                                       pressure: 1)!
        #expect(view.reportMouse(event: event, button: .left, action: .press, at: point))
        #expect(String(decoding: delegate.sentBytes, as: UTF8.self) == "\u{1b}[<0;4;3M")

        // ⇧ bypasses reporting so text can always be selected.
        let shifted = NSEvent.mouseEvent(with: .leftMouseDown,
                                         location: .zero,
                                         modifierFlags: [.shift],
                                         timestamp: 0,
                                         windowNumber: 0,
                                         context: nil,
                                         eventNumber: 0,
                                         clickCount: 1,
                                         pressure: 1)!
        #expect(!view.reportMouse(event: shifted, button: .left, action: .press, at: point))
    }

    /// DECSET 1002 reports motion while a button is held — for *every* button.
    /// AppKit hands a right- or middle-button drag to its own method, so those
    /// two used to report the press and the release with nothing in between.
    @Test func everyButtonReportsItsDragInButtonEventMode() {
        // left 0, middle 1, right 2; +32 is the motion bit (xterm ctlseqs).
        let buttons: [(String, Int, (TerminalView, NSEvent) -> Void, NSEvent.EventType)] = [
            ("left", 0, { $0.mouseDragged(with: $1) }, .leftMouseDragged),
            ("middle", 1, { $0.otherMouseDragged(with: $1) }, .otherMouseDragged),
            ("right", 2, { $0.rightMouseDragged(with: $1) }, .rightMouseDragged),
        ]
        for (name, code, drag, type) in buttons {
            let view = makeView()
            let delegate = RecordingDelegate()
            view.delegate = delegate
            view.feed("\u{1b}[?1002h\u{1b}[?1006h")   // button-event tracking, SGR

            // Two locations many cells apart, so the column differs whatever the
            // window-to-view conversion does with y.
            drag(view, makeMouseEvent(type, at: CGPoint(x: 4, y: 4)))
            let first = String(decoding: delegate.sentBytes, as: UTF8.self)
            #expect(first.hasPrefix("\u{1b}[<\(code + 32);"),
                    "\(name) drag reported \(first.debugDescription), expected a motion report")

            // xterm only speaks when the pointer enters another cell.
            delegate.sent.removeAll()
            drag(view, makeMouseEvent(type, at: CGPoint(x: 4, y: 4)))
            #expect(delegate.sent.isEmpty, "\(name) drag re-reported the same cell")

            delegate.sent.removeAll()
            drag(view, makeMouseEvent(type, at: CGPoint(x: view.cellWidth * 20 + 4, y: 4)))
            let moved = String(decoding: delegate.sentBytes, as: UTF8.self)
            #expect(moved.hasPrefix("\u{1b}[<\(code + 32);"),
                    "\(name) drag to another cell reported \(moved.debugDescription)")
            #expect(moved != first, "\(name) drag reported the same column twice")
        }
    }

    /// Normal tracking (DECSET 1000) is press/release only: a drag of any
    /// button stays silent, exactly as `MouseEncoder.filter` says.
    @Test func noButtonReportsItsDragInNormalTrackingMode() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.feed("\u{1b}[?1000h\u{1b}[?1006h")
        view.mouseDragged(with: makeMouseEvent(.leftMouseDragged, at: CGPoint(x: 4, y: 4)))
        view.rightMouseDragged(with: makeMouseEvent(.rightMouseDragged, at: CGPoint(x: 40, y: 4)))
        view.otherMouseDragged(with: makeMouseEvent(.otherMouseDragged, at: CGPoint(x: 80, y: 4)))
        #expect(delegate.sent.isEmpty)
    }

    /// ⇧ is the escape hatch out of mouse reporting; it has to work for the two
    /// new methods too, and a right-drag must then fall through untouched
    /// rather than being swallowed.
    @Test func shiftBypassesReportingForRightAndMiddleDrags() {
        let view = makeView()
        let delegate = RecordingDelegate()
        view.delegate = delegate
        view.feed("\u{1b}[?1002h\u{1b}[?1006h")
        view.rightMouseDragged(with: makeMouseEvent(.rightMouseDragged, at: CGPoint(x: 4, y: 4),
                                                    flags: [.shift]))
        view.otherMouseDragged(with: makeMouseEvent(.otherMouseDragged, at: CGPoint(x: 40, y: 4),
                                                    flags: [.shift]))
        #expect(delegate.sent.isEmpty)
    }

    @Test func accessibilityExposesTheScreen() {
        let view = makeView()
        view.feed("router#show run")
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        let value = view.accessibilityValue() as? String
        #expect(value?.hasPrefix("router#show run") == true)
    }
}

// MARK: - FindBar

@MainActor
// MARK: - IME (marked text)

/// A Japanese/Korean/Chinese input method never sends keys to the terminal: it
/// calls `setMarkedText` while the user is composing (the underlined "preedit"
/// on screen) and `insertText` once, with the finished text, when the user
/// commits. Thai has no preedit at all, so this is the only way to exercise the
/// path without switching the machine's input source.
@Suite("IME composition") struct IMETests {

    /// The underlined field the view puts on screen while composing.
    private func preeditField(_ view: TerminalView) -> NSTextField? {
        view.subviews.compactMap { $0 as? NSTextField }.first
    }

    private func notRange(_ r: NSRange) -> Bool { r.location == NSNotFound }

    @Test func composingSendsNothingAndShowsAnUnderlinedPreedit() {
        let view = makeView()
        let spy = RecordingDelegate()
        view.delegate = spy
        #expect(!view.hasMarkedText())
        #expect(notRange(view.markedRange()))

        // "ni" → に, then "niho" → にほ: the IME replaces its own marked text.
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
        #expect(view.selectedRange() == NSRange(location: 1, length: 0))
        #expect(preeditField(view)?.stringValue == "に")

        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.markedRange() == NSRange(location: 0, length: 3))
        let field = preeditField(view)
        #expect(field?.stringValue == "にほん")
        // Underlined, the way every macOS app draws an unconverted preedit.
        let attrs = field?.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        #expect(attrs?[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)

        // Nothing has reached the device, and nothing has reached the grid.
        #expect(spy.sent.isEmpty)
        #expect(view.terminal.buffer.row(line: 0)?.string(trimRight: true).isEmpty != false)
    }

    @Test func committingSendsTheFinishedTextOnceAndClearsThePreedit() {
        let view = makeView()
        let spy = RecordingDelegate()
        view.delegate = spy
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sent.isEmpty)

        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sentBytes == Array("日本".utf8))
        #expect(!view.hasMarkedText())
        #expect(notRange(view.markedRange()))
        #expect(preeditField(view) == nil)
    }

    @Test func anAttributedCommitIsSentAndAnEmptyOneIsNot() {
        let view = makeView()
        let spy = RecordingDelegate()
        view.delegate = spy
        view.insertText(NSAttributedString(string: "한국"),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sentBytes == Array("한국".utf8))
        spy.sent.removeAll()
        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sent.isEmpty)
    }

    @Test func abandoningACompositionSendsNothing() {
        let view = makeView()
        let spy = RecordingDelegate()
        view.delegate = spy
        view.setMarkedText("ㅎㅏ", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()                       // clicked away / switched app
        #expect(!view.hasMarkedText())
        #expect(preeditField(view) == nil)
        #expect(spy.sent.isEmpty)
        // An empty marked string is the other way an IME cancels.
        view.setMarkedText("は", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(preeditField(view) == nil)
        #expect(spy.sent.isEmpty)
    }

    @Test func thePreeditAndTheCandidateWindowFollowTheCursor() {
        let view = makeView()
        view.terminal.feed("switch# show ver")     // cursor is 16 columns in
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let origin = view.cursorOrigin()
        #expect(origin.x > 0)
        #expect(preeditField(view)?.frame.origin.x == origin.x)

        // Where macOS puts the candidate list: the cursor cell, one cell big.
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1),
                                  actualRange: nil)
        #expect(rect.width == view.cellWidth)
        #expect(rect.height == view.cellHeight)
        #expect(rect.origin.x == origin.x)
    }

    @Test func theRestOfTheInputClientContractIsHonoured() {
        let view = makeView()
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1),
                                         actualRange: nil) == nil)
        #expect(view.validAttributesForMarkedText().isEmpty)
        #expect(view.characterIndex(for: .zero) == NSNotFound)
        #expect(notRange(view.selectedRange()))
    }
}

@Suite struct FindBarTests {

    @Test func optionsRoundTripAndReportChanges() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
        bar.debounceInterval = 0
        var changes = 0
        bar.onChange = { _ in changes += 1 }

        bar.searchText = "vlan"
        #expect(bar.searchText == "vlan")
        #expect(changes == 1)

        bar.options = SearchOptions(caseSensitive: true, regex: true, wholeWord: true)
        #expect(bar.options == SearchOptions(caseSensitive: true, regex: true, wholeWord: true))
        bar.options = SearchOptions()
        #expect(bar.options == SearchOptions())
    }

    @Test func statusLabelSaysWhereWeAre() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
        bar.debounceInterval = 0
        bar.setMatchCount(current: nil, total: 0)
        #expect(bar.statusText == "")               // no term yet
        bar.searchText = "up"
        bar.setMatchCount(current: 3, total: 27)
        #expect(bar.statusText == "3 of 27")
        bar.setMatchCount(current: nil, total: 27)
        #expect(bar.statusText == "27 found")
        bar.setMatchCount(current: 1, total: 1000, limited: true)
        #expect(bar.statusText == "1 of 1000+")
        bar.setMatchCount(current: nil, total: 0)
        #expect(bar.statusText == "not found")
        // A pattern that was refused is not "not found": nobody looked.
        bar.setMatchCount(current: nil, total: 0, problem: .unsupported)
        #expect(bar.statusText == "not supported")
        bar.setMatchCount(current: nil, total: 0, problem: .malformed)
        #expect(bar.statusText == "bad pattern")
        bar.setMatchCount(current: nil, total: 0, problem: .tooBig)
        #expect(bar.statusText == "too complex")
        // …and neither is a search that ran out of its work budget part way
        // through: the text past that point was never examined, so "not found"
        // would be a statement about text nobody looked at.
        bar.setMatchCount(current: nil, total: 0, incomplete: true)
        #expect(bar.statusText == "too complex")
        #expect(bar.statusTooltip?.contains("stopped before the end") == true)
        // Partial results keep their count, marked "at least this many".
        bar.setMatchCount(current: nil, total: 12, incomplete: true)
        #expect(bar.statusText == "12+ found")
        bar.setMatchCount(current: 3, total: 12, incomplete: true)
        #expect(bar.statusText == "3 of 12+")
        // A complete search that finds nothing still says so.
        bar.setMatchCount(current: nil, total: 0)
        #expect(bar.statusText == "not found")
        #expect(bar.statusTooltip == nil)
        // Every one of those has to FIT. The label was a hardcoded 62 pt, and
        // "not supported" needs 68.2 — measured, after it had already shipped
        // clipped.
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 28)
        bar.layout()
        let font = NSFont.systemFont(ofSize: 10)
        for text in ["not found", "not supported", "bad pattern", "too complex", "1000+ found"] {
            let needed = (text as NSString).size(withAttributes: [.font: font]).width
            #expect(bar.countLabelWidth >= needed, "\(text) needs \(needed) pt")
        }
        bar.setMatchCount(current: 2, total: 9)
        #expect(bar.statusText == "2 of 9")
    }

    @Test func escapeAndReturnAreReportedToTheHost() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
        var closed = 0
        bar.onClose = { _ in closed += 1 }
        bar.cancelOperation(nil)
        #expect(closed == 1)
    }
}


@Suite("TerminalView grid guard") struct ViewGridGuardTests {
    final class SizeSpy: TerminalViewDelegate {
        var sizes: [(Int, Int)] = []
        func send(_ view: TerminalView, bytes: [UInt8]) {}
        func sizeChanged(_ view: TerminalView, cols: Int, rows: Int) { sizes.append((cols, rows)) }
    }

    /// Switching tabs pulls the view out of the window and SwiftUI hands it a
    /// 0×0 frame on the way: that must not become a 2×1 terminal.
    @Test func degenerateFrameKeepsTheGrid() {
        TerminalView.forceDisableMetal = true
        defer { TerminalView.forceDisableMetal = false }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480), cols: 80, rows: 24)
        let spy = SizeSpy()
        view.delegate = spy
        let cols = view.cols, rows = view.rows
        view.setFrameSize(.zero)
        #expect(view.cols == cols && view.rows == rows)
        view.setFrameSize(NSSize(width: 3, height: 2))
        #expect(view.cols == cols && view.rows == rows)
        #expect(spy.sizes.isEmpty)
    }
}

// MARK: - IME under the kitty keyboard protocol

/// The kitty keyboard protocol says nothing about how the platform turns keys
/// into text — its own text-as-code-points section has the OS eating a key to
/// produce text and handing the terminal "only a text input event". So a
/// composition must start, run and commit whatever flags the program pushed,
/// while every key the input method does *not* take keeps the encoding that
/// program asked for.
///
/// These tests drive the `NSTextInputClient` contract, not a live input method:
/// `setMarkedText`/`insertText` are what a Japanese, Korean or Chinese input
/// source would call. The keys typed through `keyDown` go through the machine's
/// real `NSTextInputContext`, which only echoes them on a plain keyboard
/// layout — `onAPlainLayout` skips those cases when an input method is selected.
@MainActor
@Suite("IME composition under kitty flags") struct IMEKittyTests {

    private func preeditField(_ view: TerminalView) -> NSTextField? {
        view.subviews.compactMap { $0 as? NSTextField }.first
    }

    /// `CSI > flags u` — how a program turns the protocol on.
    private func pushKittyFlags(_ view: TerminalView, _ flags: Int) {
        view.feed("\u{1b}[>\(flags)u")
        #expect(view.terminal.kittyKeyboardFlags == flags)
    }

    private func onAPlainLayout(_ view: TerminalView) -> Bool {
        (view.inputContext?.selectedKeyboardInputSource ?? "")
            .hasPrefix("com.apple.keylayout.")
    }

    private func makeSpy(_ view: TerminalView) -> RecordingDelegate {
        let spy = RecordingDelegate()
        view.delegate = spy
        return spy
    }

    /// 1 = disambiguate alone (the flag that used to be enough to lock a whole
    /// language out), 3 = + event types, 9 = report-all-keys, 31 = everything.
    private static let flagSets = [1, 3, 9, 31]

    /// What `日本` looks like on the wire for a given flag set: plain UTF-8,
    /// unless the program asked for report-all-keys **and** report-associated-
    /// text, which is the spec's pure "text event" — key number 0, no
    /// modifiers, code points separated by colons.
    private func committedBytes(_ flags: Int) -> [UInt8] {
        (flags & 9) == 9 && (flags & 16) != 0
            ? Array("\u{1b}[0;;26085:26412u".utf8)
            : Array("日本".utf8)
    }

    @Test func aCompositionRunsAndCommitsWhateverTheFlagsAre() {
        for flags in Self.flagSets {
            let view = makeView()
            let spy = makeSpy(view)
            pushKittyFlags(view, flags)

            view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(view.hasMarkedText(), "flags \(flags)")
            #expect(preeditField(view)?.stringValue == "にほ", "flags \(flags)")
            #expect(spy.sent.isEmpty, "flags \(flags): a preedit is not typed yet")

            view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(spy.sent.isEmpty, "flags \(flags)")

            // Committed text is text: plain UTF-8, or the code-point form when
            // the program asked for text as code points.
            view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(spy.sentBytes == committedBytes(flags), "flags \(flags)")
            #expect(!view.hasMarkedText(), "flags \(flags)")
            #expect(preeditField(view) == nil, "flags \(flags)")
        }
    }

    /// The other half of the bargain: a key the input method only echoes still
    /// leaves as the encoding the program asked for — `a` under report-all-keys
    /// is `CSI 97 u`, not the letter the input context handed back.
    @Test func anEchoedKeyKeepsItsKittyEncoding() {
        let probe = makeView()
        guard onAPlainLayout(probe) else { return }

        let cases: [(Int, String)] = [
            (0, "a"),                       // legacy: unchanged
            (1, "a"),                       // disambiguate leaves text alone
            (3, "a"),
            (9, "\u{1b}[97u"),              // report-all-keys: the key, not the text
            (25, "\u{1b}[97;;97u"),         // + report associated text
        ]
        for (flags, expected) in cases {
            let view = makeView()
            let spy = makeSpy(view)
            if flags != 0 { pushKittyFlags(view, flags) }
            view.keyDown(with: makeEvent(0, characters: "a", ignoring: "a"))
            #expect(String(decoding: spy.sentBytes, as: UTF8.self) == expected,
                    "flags \(flags)")
        }
    }

    /// Every ordinary typing key is offered to the input method now, so every
    /// one of them has to come back out of the encoder unchanged — in the
    /// legacy encoding and in the protocol's.
    @Test func ordinaryTypingKeysAreUnchangedByTheOffer() {
        let probe = makeView()
        guard onAPlainLayout(probe) else { return }

        // (keyCode, characters, charactersIgnoringModifiers, modifiers,
        //  legacy bytes, report-all-keys bytes)
        let keys: [(UInt16, String, String, NSEvent.ModifierFlags, String, String)] = [
            (49, " ", " ", [], " ", "\u{1b}[32u"),
            (18, "1", "1", [], "1", "\u{1b}[49u"),
            (41, ";", ";", [], ";", "\u{1b}[59u"),
            (0, "A", "A", [.shift], "A", "\u{1b}[97;2u"),
        ]
        for (code, chars, ignoring, mods, legacy, kitty) in keys {
            let plain = makeView()
            let plainSpy = makeSpy(plain)
            plain.keyDown(with: makeEvent(code, characters: chars, ignoring: ignoring,
                                          flags: mods))
            #expect(String(decoding: plainSpy.sentBytes, as: UTF8.self) == legacy,
                    "legacy \(chars.debugDescription)")

            let view = makeView()
            let spy = makeSpy(view)
            pushKittyFlags(view, 9)
            view.keyDown(with: makeEvent(code, characters: chars, ignoring: ignoring,
                                         flags: mods))
            #expect(String(decoding: spy.sentBytes, as: UTF8.self) == kitty,
                    "kitty \(chars.debugDescription)")
        }
    }

    /// While a preedit is on screen the program hears nothing: a key the input
    /// method looked at and declined must not reach the encoder either, or an
    /// Enter would run a half-typed command line.
    @Test func keysDuringACompositionDoNotReachTheProgram() {
        let view = makeView()
        guard onAPlainLayout(view) else { return }
        let spy = makeSpy(view)
        pushKittyFlags(view, 1)

        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: makeEvent(36, characters: "\r"))
        view.keyDown(with: makeEvent(126, characters: functionKeyString(NSUpArrowFunctionKey),
                                     flags: [.function, .numericPad]))
        view.keyDown(with: makeEvent(123, characters: functionKeyString(NSLeftArrowFunctionKey),
                                     flags: [.function, .numericPad]))
        #expect(spy.sent.isEmpty)
        #expect(view.hasMarkedText())        // the composition is still the user's

        // Commit, and the same keys are the terminal's again.
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sentBytes == Array("日本".utf8))
        spy.sent.removeAll()

        view.keyDown(with: makeEvent(36, characters: "\r"))
        #expect(spy.sentBytes == [0x0d])
        spy.sent.removeAll()
        view.keyDown(with: makeEvent(126, characters: functionKeyString(NSUpArrowFunctionKey),
                                     flags: [.function, .numericPad]))
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "\u{1b}[A")
    }

    /// Abandoning a composition (⎋, or clicking away) types nothing and hands
    /// the keyboard back — including the kitty encodings of report-all-keys.
    @Test func cancellingACompositionUnderKittyFlagsTypesNothing() {
        let view = makeView()
        guard onAPlainLayout(view) else { return }
        let spy = makeSpy(view)
        pushKittyFlags(view, 9)              // disambiguate + report all keys

        view.setMarkedText("ㅎㅏ", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(spy.sent.isEmpty)
        #expect(preeditField(view) == nil)

        view.keyDown(with: makeEvent(0, characters: "a", ignoring: "a"))
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "\u{1b}[97u")
        spy.sent.removeAll()
        view.keyDown(with: makeEvent(36, characters: "\r"))
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "\u{1b}[13u")

        // The other cancel: an empty marked string.
        spy.sent.removeAll()
        view.setMarkedText("は", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(spy.sent.isEmpty)
        view.keyDown(with: makeEvent(0, characters: "a", ignoring: "a"))
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "\u{1b}[97u")
    }

    /// Flags are per buffer and pop back: a composition is not disturbed by
    /// either, and the keys after the pop are legacy again.
    @Test func poppingTheFlagsMidCompositionLeavesTheCompositionAlone() {
        let view = makeView()
        guard onAPlainLayout(view) else { return }
        let spy = makeSpy(view)
        pushKittyFlags(view, 9)

        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.feed("\u{1b}[<u")               // the program popped its flags
        #expect(view.terminal.kittyKeyboardFlags == 0)
        #expect(view.hasMarkedText())
        #expect(spy.sent.isEmpty)

        view.insertText("荷", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(spy.sentBytes == Array("荷".utf8))
        spy.sent.removeAll()
        view.keyDown(with: makeEvent(0, characters: "a", ignoring: "a"))
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "a")
    }

    /// *Report associated text* (16) on top of *report all keys* (8) is the one
    /// flag state where a commit stops being UTF-8: the OS gave the terminal a
    /// text input event and no key, which the spec says is key number `0`, no
    /// modifiers, code points separated by colons.
    @Test func aCommitIsReportedAsCodePointsUnderReportText() {
        // (flags, the bytes 日本 leaves as)
        let cases: [(Int, String)] = [
            (0,  "日本"),                        // legacy
            (1,  "日本"),                        // disambiguate
            (9,  "日本"),                        // report-all-keys, no text flag
            (16, "日本"),                        // text flag alone is undefined
            (17, "日本"),                        // …and still is with disambiguate
            (24, "\u{1b}[0;;26085:26412u"),      // 8 + 16: the text event
            (25, "\u{1b}[0;;26085:26412u"),
            (31, "\u{1b}[0;;26085:26412u"),      // event types add nothing
        ]
        for (flags, expected) in cases {
            let view = makeView()
            let spy = makeSpy(view)
            if flags != 0 { pushKittyFlags(view, flags) }
            view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(String(decoding: spy.sentBytes, as: UTF8.self) == expected,
                    "flags \(flags)")
            #expect(!view.hasMarkedText(), "flags \(flags)")
        }
    }

    /// The other route into the same commit: an input method that answers the
    /// key we offered it with its own text (Pinyin turning `,` into `，`),
    /// instead of committing later on its own clock. Both must encode alike.
    ///
    /// A plain layout only ever echoes the key back, so the offer is told the
    /// key typed something else — that is what makes the echo look like an
    /// input method's own text and takes the branch a live IME takes.
    @Test func aCommitOnTheOfferRouteIsEncodedTheSameWay() {
        let view = makeView()
        guard onAPlainLayout(view), let context = view.inputContext else { return }
        let spy = makeSpy(view)
        pushKittyFlags(view, 25)
        let took = view.offerToInputMethod(makeEvent(0, characters: "a", ignoring: "a"),
                                           to: context, typed: "x")
        #expect(took)
        #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "\u{1b}[0;;97u")

        // Legacy: the same route, the same text, the bytes it always sent.
        let plain = makeView()
        let plainSpy = makeSpy(plain)
        guard let plainContext = plain.inputContext else { return }
        #expect(plain.offerToInputMethod(makeEvent(0, characters: "a", ignoring: "a"),
                                         to: plainContext, typed: "x"))
        #expect(plainSpy.sentBytes == Array("a".utf8))
    }

    /// A paste is not a text input event: the protocol is scoped to key events
    /// and never mentions paste, and its "no control codes" rule could not
    /// carry the CR a multi-line paste is made of. Bracketed paste stays the
    /// only framing a paste gets, whatever the flags.
    @Test func aPasteIsUnaffectedByTheTextFlags() {
        for flags in [0, 9, 25, 31] {
            let view = makeView()
            let spy = makeSpy(view)
            let board = privateBoard("kitty-paste-\(flags)")
            board.setString("show run\nshow ver", forType: .string)
            view.pasteboard = board
            if flags != 0 { pushKittyFlags(view, flags) }

            view.paste(nil)
            #expect(String(decoding: spy.sentBytes, as: UTF8.self) == "show run\rshow ver",
                    "flags \(flags)")

            spy.sent.removeAll()
            view.feed("\u{1b}[?2004h")
            view.paste(nil)
            #expect(String(decoding: spy.sentBytes, as: UTF8.self)
                    == "\u{1b}[200~show run\rshow ver\u{1b}[201~", "flags \(flags)")
        }
    }
}
