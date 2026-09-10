// FuzzLimitsTests.swift — SheepVT
//
// The caps the random generator cannot reach cheaply: the parser's 8 MiB
// OSC/APC payload limit, the 4096-byte DCS limit, and the hyperlink table's
// byte budget. Each is fed in irregular chunks, with the terminator split
// across a feed boundary, and the grid invariants are checked afterwards —
// an over-long string must be dropped whole, never truncated and dispatched,
// and must not leave the payload buffer holding the bytes.

import Foundation
import Testing

@testable import SheepVT

@Suite("SheepVT fuzz limits", .serialized)
struct FuzzLimitsTests {

    /// Feed `bytes` in pseudo-random pieces, so every cap is crossed at an
    /// arbitrary offset inside a chunk.
    private func feedInPieces(_ t: Terminal, _ bytes: [UInt8], seed: UInt64) {
        var rng = Xorshift64RNG(seed: seed)
        var i = 0
        while i < bytes.count {
            let n = 1 + Int(rng.next() % 65_536)
            let end = Swift.min(i + n, bytes.count)
            bytes[i..<end].withUnsafeBufferPointer { t.feed($0) }
            i = end
        }
    }

    private func expectHealthy(_ t: Terminal, _ what: String) {
        let bad = GridInvariants.check(t)
        #expect(bad.isEmpty, Comment(rawValue: "\(what): \(bad.map(\.description).joined(separator: "; "))"))
    }

    @Test("an OSC payload past the 8 MiB cap is dropped whole, not truncated")
    func oscPayloadOverCap() {
        final class Recorder: TerminalDelegate {
            var titles: [String] = []
            func titleChanged(_ terminal: Terminal, title: String) { titles.append(title) }
        }
        let host = Recorder()
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        t.delegate = host

        var bytes = Array("\u{1b}]2;".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: "T"), count: VTParser.maxPayload + 4096)
        bytes += [0x07]
        feedInPieces(t, bytes, seed: 0xB16B_0000_0001)

        #expect(host.titles.isEmpty, "an over-long OSC must not be dispatched at all")
        #expect(t.title == "")
        expectHealthy(t, "after an over-long OSC")

        // The parser must be usable straight afterwards.
        t.feed(Array("\u{1b}]2;ok\u{7}".utf8))
        #expect(t.title == "ok")
        #expect(host.titles == ["ok"])
    }

    @Test("an over-long OSC does not keep the bytes alive")
    func oscPayloadReleased() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        var bytes = Array("\u{1b}]2;".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: "T"), count: VTParser.maxPayload + 1)
        bytes += [0x07]
        feedInPieces(t, bytes, seed: 0xB16B_0000_0002)
        // `VTParser.append` drops the buffer's capacity (`removeAll(keepingCapacity: false)`)
        // when it overflows, and `endString` clears it. Feeding a short OSC after
        // must produce exactly that short payload.
        t.feed(Array("\u{1b}]2;short\u{7}".utf8))
        #expect(t.title == "short")
        expectHealthy(t, "after an over-long OSC then a short one")
    }

    @Test("a DCS payload past 4096 bytes is abandoned, and the next one still works")
    func dcsPayloadOverCap() {
        final class Replies: TerminalDelegate {
            var sent: [String] = []
            func send(_ terminal: Terminal, bytes: [UInt8]) {
                sent.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        let host = Replies()
        let t = Terminal(cols: 20, rows: 5, scrollback: 50)
        t.delegate = host

        var bytes = Array("\u{1b}P$q".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: "m"), count: Terminal.maxDCSPayload + 100)
        bytes += Array("\u{1b}\\".utf8)
        feedInPieces(t, bytes, seed: 0xB16B_0000_0003)
        #expect(host.sent.isEmpty, "an over-long DECRQSS must be abandoned, not answered")
        #expect(!t.dcsActive)
        #expect(!t.dcsOverflowed)

        // A well-formed DECRQSS right afterwards must still be answered.
        t.feed(Array("\u{1b}P$qm\u{1b}\\".utf8))
        #expect(host.sent.count == 1)
        #expect(host.sent.first?.contains("0m") == true)
        expectHealthy(t, "after an over-long DCS")
    }

    @Test("a string terminator split across a feed boundary still terminates")
    func splitTerminator() {
        for split in 0..<2 {
            let t = Terminal(cols: 20, rows: 5, scrollback: 10)
            t.feed(Array("\u{1b}]2;title".utf8))
            if split == 0 {
                t.feed([0x1B])              // ESC of ST alone…
                t.feed([0x5C])              // …then the backslash
            } else {
                t.feed(Array("\u{1b}\\".utf8))
            }
            #expect(t.title == "title", "split \(split)")
            expectHealthy(t, "split terminator \(split)")
        }
    }

    @Test("the hyperlink table stays inside its byte budget")
    func hyperlinkBudget() {
        let t = Terminal(cols: 40, rows: 4, scrollback: 200)
        // Long, never-repeating URIs: the shape that would grow the table
        // forever if the budget were not counted.
        let filler = String(repeating: "p", count: 4000)
        var registered = 0
        for i in 0..<3000 {
            t.feed(Array("\u{1b}]8;id=\(i);https://example.com/\(filler)/\(i)\u{1b}\\".utf8))
            t.feed(Array("x".utf8))
            if t.hyperlinks.count > registered { registered = t.hyperlinks.count }
            if i % 200 == 0 { t.feed(Array("\r\n".utf8)) }
        }
        #expect(t.hyperlinkBytes <= Terminal.maxHyperlinkBytes)
        #expect(t.hyperlinks.count <= Terminal.maxHyperlinks)
        #expect(registered > 0, "some links should have been registered before the budget ran out")
        expectHealthy(t, "after the hyperlink budget ran out")

        // Every id sitting in a cell must still point inside the table.
        let b = t.buffer
        for i in 0..<b.lineCount {
            guard let row = b.lines.allocatedRow(at: i) else { continue }
            for c in 0..<row.cols {
                if let e = row.extended(at: c) {
                    #expect(e.hyperlinkID <= UInt32(t.hyperlinks.count))
                }
            }
        }
    }

    @Test("an APC that never terminates does not grow without bound")
    func unterminatedAPC() {
        let t = Terminal(cols: 20, rows: 5, scrollback: 20)
        var bytes = Array("\u{1b}_".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: "A"), count: VTParser.maxPayload + 2048)
        feedInPieces(t, bytes, seed: 0xB16B_0000_0004)
        expectHealthy(t, "mid-APC")
        // Terminate it now: the payload was dropped, so nothing is dispatched,
        // and the terminal goes back to printing.
        t.feed(Array("\u{1b}\\hello".utf8))
        expectHealthy(t, "after an over-long APC")
        #expect(t.screenLines().first?.hasPrefix("hello") == true)
    }
}
