// FixtureTests.swift — SheepVT
//
// Replays the xterm.js escape-sequence fixtures (Tests/Fixtures/xtermjs/*.in + *.text,
// MIT — see the LICENSE file alongside them) through `Terminal` and compares the
// resulting 80x25 screen against the recorded expectation.

import Foundation
import Testing

import SheepVT

// MARK: - Fixture discovery

/// One fixture: `tNNNN-name.in` (raw bytes to feed) paired with `tNNNN-name.text`
/// (the expected 80x25 screen).
struct Fixture: Sendable, CustomTestStringConvertible {
    let name: String
    let inputURL: URL
    let textURL: URL

    var testDescription: String { name }
}

enum FixtureCorpus {
    /// `Tests/Fixtures` is copied into the test bundle as a resource by `Package.swift`;
    /// the xterm.js fixtures live in its `xtermjs` subdirectory.
    static let directoryURL: URL? = {
        guard let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            return nil
        }
        return base.appendingPathComponent("xtermjs", isDirectory: true)
    }()

    /// Every `tNNNN-name.in` paired with its `.text`, sorted by name so each fixture
    /// reports individually and in a stable order.
    static let all: [Fixture] = {
        guard let dir = directoryURL,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return
            entries
            .filter { $0.pathExtension == "in" }
            .map { url -> Fixture in
                let name = url.deletingPathExtension().lastPathComponent
                let textURL = url.deletingPathExtension().appendingPathExtension("text")
                return Fixture(name: name, inputURL: url, textURL: textURL)
            }
            .sorted { $0.name < $1.name }
    }()
}

/// Fixtures known to disagree with SheepVT on purpose, or that xterm.js itself skips.
/// Grows only with a one-line reason per entry.
enum FixtureSkipList {
    static let skipped: [String: String] = [
        "t0084-CBT": "xterm.js skips this fixture upstream",
        "t0103-reverse_wrap": "deviates from xterm on purpose",
        "t0504-vim": "xterm.js skips this fixture upstream",
    ]
}

// MARK: - Cooked-mode feed rule

/// The fixtures were captured through a pty in cooked mode, where the driver's LF became
/// CRLF (ONLCR). Undo that here: every `\n` (0x0A) NOT already preceded by `\r` (0x0D)
/// becomes `\r\n`; every other byte is fed through unchanged.
func cookedBytes(from raw: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(raw.count + raw.count / 8)
    var previous: UInt8 = 0
    for byte in raw {
        if byte == 0x0A, previous != 0x0D {
            out.append(0x0D)
        }
        out.append(byte)
        previous = byte
    }
    return out
}

// MARK: - Expected screen

/// `.text` files hold 25 lines of screen content each ending in `\n` (so splitting on
/// `"\n"` yields 26 elements, the last one empty — drop it). Trailing whitespace on each
/// kept line is stripped to match `screenLines(trimRight: true)`.
func expectedLines(from data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" {
        lines.removeLast()
    }
    return lines.map { line in
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" {
            s.removeLast()
        }
        return String(s)
    }
}

// MARK: - Running one fixture

struct FixtureComputation {
    let got: [String]
    let expected: [String]
}

/// Feeds the fixture through a fresh `Terminal` and returns both the produced screen and
/// the expected one, without judging pass/fail — shared by the per-fixture test and the
/// summary test.
func computeFixture(_ fixture: Fixture) throws -> FixtureComputation {
    let rawInput = try Data(contentsOf: fixture.inputURL)
    let expectedData = try Data(contentsOf: fixture.textURL)

    let terminal = Terminal(cols: 80, rows: 25, scrollback: 1000)
    terminal.feed(cookedBytes(from: [UInt8](rawInput)))

    return FixtureComputation(
        got: terminal.screenLines(trimRight: true),
        expected: expectedLines(from: expectedData)
    )
}

/// A readable row-by-row diff for the `#expect` failure message: only differing rows are
/// printed, each as `row N` / `exp |...|` / `got |...|`.
func fixtureDiff(name: String, expected: [String], got: [String]) -> String {
    var lines = [
        "\(name): screen mismatch (expected \(expected.count) rows, got \(got.count))"
    ]
    let count = max(expected.count, got.count)
    for row in 0..<count {
        let e = row < expected.count ? expected[row] : "<missing row>"
        let g = row < got.count ? got[row] : "<missing row>"
        guard e != g else { continue }
        lines.append("row \(row)")
        lines.append("exp |\(e)|")
        lines.append("got |\(g)|")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Tests

@Suite("SheepVT xterm.js fixtures", .serialized)
struct FixtureTests {

    /// One test case per fixture file, so failures are reported individually.
    @Test("fixture", arguments: FixtureCorpus.all)
    func fixture(_ fixture: Fixture) throws {
        if let reason = FixtureSkipList.skipped[fixture.name] {
            Issue.record("skipped: \(reason)", severity: .warning)
            return
        }

        let result = try computeFixture(fixture)
        #expect(
            result.got == result.expected,
            "\(fixtureDiff(name: fixture.name, expected: result.expected, got: result.got))"
        )
    }

    /// Runs every fixture again and prints an overall pass/fail/skip tally, so the totals
    /// are visible in one place without scrolling through 76 individual results.
    @Test("all fixtures summary")
    func summary() throws {
        var passCount = 0
        var failCount = 0
        var skipCount = 0
        var failures: [String] = []

        for fixture in FixtureCorpus.all {
            if FixtureSkipList.skipped[fixture.name] != nil {
                skipCount += 1
                continue
            }
            let result = try computeFixture(fixture)
            if result.got == result.expected {
                passCount += 1
            } else {
                failCount += 1
                failures.append(fixture.name)
            }
        }

        print("fixtures: \(passCount) pass, \(failCount) fail, \(skipCount) skipped")
        if !failures.isEmpty {
            print("failed: \(failures.joined(separator: ", "))")
        }

        #expect(failCount == 0, "fixtures failed: \(failures.joined(separator: ", "))")
    }
}
