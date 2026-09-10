// ReplayTests.swift — SheepVT
//
// Replays SheepTerm's own captured device logs through `Terminal` three ways — whole
// file, one byte at a time, and in pseudo-random chunk sizes — and checks they all
// produce an identical buffer. This is the chunk-invariance guarantee the parser and
// terminal state machine both depend on: a device stream can arrive split at any byte
// boundary, and the result must not depend on where the splits fall.

import Foundation
import Testing

import SheepVT

// MARK: - Seeded RNG

/// A tiny, deterministic xorshift64 generator. `SystemRandomNumberGenerator` is not
/// seeded, and this test needs the same chunk-size sequence on every run so a failure
/// is reproducible.
struct Xorshift64RNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift64 requires a non-zero state.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Corpus discovery

enum ReplayCorpus {
    /// Derived, not written out. A literal home path pins the corpus to one
    /// account, and this file is exported to the public repository — where one
    /// person's directory layout has no business being. `SHEEPVT_REPLAY_DIR`
    /// overrides it for a machine that keeps its logs elsewhere.
    static let directoryURL: URL = {
        if let override = ProcessInfo.processInfo.environment["SHEEPVT_REPLAY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SheepTerm Logs", isDirectory: true)
    }()

    /// Every `*.log` in the corpus directory, sorted by name. Empty if the directory is
    /// missing or contains no logs — callers treat that as "skip", not "fail".
    ///
    /// `ZZ-` names are skipped. The corpus is the user's real session logs, and the test
    /// harnesses write into the same folder (`ZZ-sshtest-…`, `ZZ-backpressure-…`): a run that
    /// enumerated those would replay whatever another test happened to be writing, and would
    /// fail outright when such a file was deleted between the listing and the read.
    static let logFiles: [URL] = {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return
            entries
            .filter { $0.pathExtension == "log" && !$0.lastPathComponent.hasPrefix("ZZ-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()
}

// MARK: - Chunked feeding

/// Feeds `bytes` to `terminal`, drawing each chunk's length from `nextChunkSize` (called
/// repeatedly until the bytes are exhausted). Chunk sizes are clamped to at least 1 so a
/// generator that returns 0 cannot spin forever.
func feedChunked(_ bytes: [UInt8], to terminal: Terminal, nextChunkSize: () -> Int) {
    var index = 0
    while index < bytes.count {
        let size = max(1, nextChunkSize())
        let end = min(index + size, bytes.count)
        terminal.feed(Array(bytes[index..<end]))
        index = end
    }
}

// MARK: - Tests

@Suite("SheepVT device log replay", .serialized)
struct ReplayTests {

    @Test("replay corpus")
    func replay() throws {
        let files = ReplayCorpus.logFiles
        guard !files.isEmpty else {
            Issue.record(
                "SheepVT replay corpus not found (or empty) at \"\(ReplayCorpus.directoryURL.path)\" — skipping",
                severity: .warning
            )
            return
        }

        let clock = ContinuousClock()
        var totalBytes = 0
        var totalElapsed = Duration.zero

        for (index, fileURL) in files.enumerated() {
            let data = try Data(contentsOf: fileURL)
            let bytes = [UInt8](data)
            totalBytes += bytes.count

            let elapsed = clock.measure {
                // (a) whole file in one feed.
                let whole = Terminal(cols: 200, rows: 50, scrollback: 10_000)
                whole.feed(bytes)

                // (b) one byte at a time.
                let byByte = Terminal(cols: 200, rows: 50, scrollback: 10_000)
                for byte in bytes {
                    byByte.feed([byte])
                }

                // (c) pseudo-random chunk sizes 1...4096, from a seeded generator so the
                // run is reproducible.
                var rng = Xorshift64RNG(seed: 0x1234_5678_9ABC_DEF0 &+ UInt64(index))
                let chunked = Terminal(cols: 200, rows: 50, scrollback: 10_000)
                feedChunked(bytes, to: chunked) { Int.random(in: 1...4096, using: &rng) }

                let wholeLines = whole.allLines()
                let byByteLines = byByte.allLines()
                let chunkedLines = chunked.allLines()

                #expect(
                    wholeLines == byByteLines,
                    "\(fileURL.lastPathComponent): byte-at-a-time feed diverged from whole-file feed"
                )
                #expect(
                    wholeLines == chunkedLines,
                    "\(fileURL.lastPathComponent): random-chunk feed diverged from whole-file feed"
                )
                #expect(
                    whole.screenLines().count == 50,
                    "\(fileURL.lastPathComponent): screen should always report exactly `rows` lines"
                )
            }

            totalElapsed += elapsed
            print("\(fileURL.lastPathComponent): \(bytes.count) bytes in \(elapsed)")
        }

        print(
            "replay: \(files.count) files, \(totalBytes) bytes total in \(totalElapsed)"
        )
    }
}
