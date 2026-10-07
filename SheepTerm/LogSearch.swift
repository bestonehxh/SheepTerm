import Foundation

/// File → Search Logs… (4.2 (4)): one query across every session log in
/// `SessionLogger.logsDirectory` — "which switch did I see that MAC on",
/// "when did that interface last flap".
///
/// Pure and `nonisolated`: compiled into `Tests/run.sh tests` and driven on a
/// scratch folder there. The sheet runs it on a background queue and polls
/// `isCancelled` so a new keystroke abandons the run in progress.
nonisolated enum LogSearch {
    /// Hits reported per run, at most. Past this the results are a list
    /// nobody reads; the status line says it was cut.
    static let maxHits = 2000
    /// A hit's line is cut to this many characters for the list.
    static let maxLineChars = 300
    /// Bytes read per `read` — a line is never longer than this in practice;
    /// one that is gets split, which is harmless for a search.
    static let chunkBytes = 1 << 20
    /// Bytes without a newline that are flushed as a line of their own.
    static let maxCarryBytes = 4 << 20
    /// The most of one line the matcher looks at. A regex that is harmless
    /// on log lines can be exponential on a multi-megabyte one (a config
    /// dump without newlines, a binary wearing .log), and a match cannot be
    /// cancelled from outside — so a line is matched on its head only. The
    /// list shows 300 characters anyway.
    static let maxMatchBytes = 64 << 10

    struct Query: Equatable, Sendable {
        var text: String
        var regex = false
        var caseSensitive = false
    }

    struct Hit: Equatable, Sendable, Identifiable {
        var id: String { "\(file.path):\(line)" }
        var file: URL
        /// 1-based line number in the file.
        var line: Int
        /// The line, trimmed and cut to `maxLineChars`.
        var text: String
    }

    struct FileResult: Equatable, Sendable, Identifiable {
        var id: String { file.path }
        var file: URL
        var hits: [Hit]
    }

    struct Outcome: Equatable, Sendable {
        var results: [FileResult] = []
        var total = 0
        var filesSearched = 0
        var unreadable = 0
        var truncated = false
        var cancelled = false
    }

    enum Failure: Error, Equatable {
        case emptyQuery
        case badRegex(String)
    }

    /// The `.log` files in `directory`, newest first.
    static func files(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var dated: [(URL, Date)] = []
        for url in names where url.pathExtension.lowercased() == "log" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            dated.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The matcher for a query, or why there is none.
    static func matcher(for query: Query) throws -> Matcher {
        let text = query.text
        guard !text.isEmpty else { throw Failure.emptyQuery }
        if query.regex {
            do {
                let regex = try NSRegularExpression(pattern: text, options: query.caseSensitive ? [] : [.caseInsensitive])
                return Matcher(regex: regex, literal: nil, caseSensitive: query.caseSensitive)
            } catch {
                throw Failure.badRegex(error.localizedDescription)
            }
        }
        return Matcher(regex: nil, literal: text, caseSensitive: query.caseSensitive)
    }

    struct Matcher: Sendable {
        let regex: NSRegularExpression?
        let literal: String?
        let caseSensitive: Bool

        func matches(_ line: String) -> Bool {
            if let regex {
                return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            }
            guard let literal else { return false }
            return line.range(of: literal, options: caseSensitive ? [] : [.caseInsensitive]) != nil
        }
    }

    /// Search `files` in the order given. Stops at `maxHits` or when
    /// `isCancelled` says so (checked between chunks, so a stale run ends
    /// within a megabyte of input).
    static func run(_ query: Query, in files: [URL], isCancelled: () -> Bool = { false }) throws -> Outcome {
        let matcher = try matcher(for: query)
        var outcome = Outcome()
        for file in files {
            if isCancelled() { outcome.cancelled = true; break }
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                outcome.unreadable += 1
                continue
            }
            defer { try? handle.close() }
            outcome.filesSearched += 1
            var hits: [Hit] = []
            var carry = Data()
            var lineNumber = 0
            var stop = false
            while !stop {
                if isCancelled() { outcome.cancelled = true; stop = true; break }
                let chunk = (try? handle.read(upToCount: chunkBytes)) ?? Data()
                let atEnd = chunk.isEmpty
                var data = carry
                data.append(chunk)
                carry = Data()
                var start = data.startIndex
                while let newline = data[start...].firstIndex(of: 0x0A) {
                    lineNumber += 1
                    consider(data[start..<newline], lineNumber: lineNumber, file: file, matcher: matcher,
                             into: &hits, outcome: &outcome, stop: &stop)
                    start = newline + 1
                    if stop { break }
                }
                if stop { break }
                if atEnd {
                    if start < data.endIndex {
                        lineNumber += 1
                        consider(data[start...], lineNumber: lineNumber, file: file, matcher: matcher,
                                 into: &hits, outcome: &outcome, stop: &stop)
                    }
                    break
                }
                carry = Data(data[start...])
                // A "line" longer than a few chunks is not a log line (a
                // binary file wearing .log): treat what is held as one line
                // and move on, or the carry would grow — and be rescanned —
                // for the whole file.
                if carry.count >= maxCarryBytes {
                    lineNumber += 1
                    consider(carry, lineNumber: lineNumber, file: file, matcher: matcher,
                             into: &hits, outcome: &outcome, stop: &stop)
                    carry = Data()
                }
            }
            if !hits.isEmpty { outcome.results.append(FileResult(file: file, hits: hits)) }
            if outcome.truncated || outcome.cancelled { break }
        }
        return outcome
    }

    private static func consider(_ bytes: Data, lineNumber: Int, file: URL, matcher: Matcher,
                                 into hits: inout [Hit], outcome: inout Outcome, stop: inout Bool) {
        var line = String(decoding: bytes.count > maxMatchBytes ? bytes.prefix(maxMatchBytes) : bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        guard matcher.matches(line) else { return }
        let shown = line.count > maxLineChars ? String(line.prefix(maxLineChars)) + "…" : line
        hits.append(Hit(file: file, line: lineNumber, text: shown))
        outcome.total += 1
        if outcome.total >= maxHits {
            outcome.truncated = true
            stop = true
        }
    }
}
