import Foundation

/// The Logs window's list (6.1, the user: "list the log files in the app,
/// linked to the folder, open one as a tab"). Pure: reads names, sizes and
/// dates; groups and filters. The harness checks it (`Tests/tests/LogLibraryTests.swift`).
nonisolated enum LogLibrary {
    struct Entry: Identifiable, Equatable, Sendable {
        let url: URL
        /// The session the log belongs to — the name before the stamp.
        let session: String
        /// When the session started (the name's stamp), else the file's date.
        let started: Date
        let modified: Date
        let size: Int64
        var id: String { url.path }
        var fileName: String { url.lastPathComponent }
    }

    /// `SessionLogger`'s name: "<session> yyyy-MM-dd HHmmss-XXXX.log".
    /// nil for a name that is not one of ours (it is still listed, by date).
    static func parse(_ fileName: String) -> (session: String, started: Date)? {
        guard fileName.hasSuffix(".log") else { return nil }
        let base = String(fileName.dropLast(4))
        // "-XXXX" (4 hex) then " yyyy-MM-dd HHmmss" before it.
        guard base.count > 23, let dash = base.lastIndex(of: "-") else { return nil }
        let unique = base[base.index(after: dash)...]
        guard unique.count == 4, unique.allSatisfy(\.isHexDigit) else { return nil }
        let head = base[..<dash]
        guard head.count > 18 else { return nil }
        let stampStart = head.index(head.endIndex, offsetBy: -17)
        let stamp = String(head[stampStart...])
        let before = head[..<stampStart]
        guard before.last == " " else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        guard let date = formatter.date(from: stamp) else { return nil }
        let session = String(before.dropLast())
        return session.isEmpty ? nil : (session, date)
    }

    /// Every `.log` in `directory`, newest first.
    static func scan(_ directory: URL, fileManager: FileManager = .default) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Entry? in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            let modified = values.contentModificationDate ?? .distantPast
            let parsed = parse(url.lastPathComponent)
            return Entry(url: url, session: parsed?.session ?? url.deletingPathExtension().lastPathComponent,
                         started: parsed?.started ?? modified, modified: modified, size: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.started != $1.started ? $0.started > $1.started : $0.fileName < $1.fileName }
    }

    /// Search: every word must be in the session name or the file name, any case.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let hay = (entry.session + " " + entry.fileName).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    enum Day: Hashable, Sendable {
        case today, yesterday, date(DateComponents)
    }

    /// Entries by the day their session started, in the order given.
    static func byDay(_ entries: [Entry], now: Date, calendar: Calendar = .current) -> [(day: Day, entries: [Entry])] {
        var out: [(day: Day, entries: [Entry])] = []
        for entry in entries {
            let day: Day
            if calendar.isDate(entry.started, inSameDayAs: now) {
                day = .today
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(entry.started, inSameDayAs: yesterday) {
                day = .yesterday
            } else {
                day = .date(calendar.dateComponents([.year, .month, .day], from: entry.started))
            }
            if out.last?.day == day { out[out.count - 1].entries.append(entry) } else { out.append((day, [entry])) }
        }
        return out
    }

    /// A log still being written: touched within `window` seconds.
    static func isLive(_ entry: Entry, now: Date, window: TimeInterval = 15) -> Bool {
        now.timeIntervalSince(entry.modified) < window
    }

    /// What a log tab shows: the file's last `limit` bytes (a whole log of a
    /// long session is far past the terminal's scrollback), cut at a line
    /// start, with bare LF made CRLF so the terminal starts each line at the left.
    static func viewerBytes(_ data: Data, limit: Int = 4 << 20) -> (bytes: [UInt8], cut: Bool) {
        var slice = [UInt8](data.count > limit ? data.suffix(limit) : data)
        let cut = data.count > limit
        if cut, let newline = slice.firstIndex(of: 0x0A) { slice.removeSubrange(...newline) }
        var out: [UInt8] = []
        out.reserveCapacity(slice.count + slice.count / 32)
        var previous: UInt8 = 0
        for byte in slice {
            if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        return (out, cut)
    }
}
