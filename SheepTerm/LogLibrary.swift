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

    /// Move to Trash is refused for a log a session is still writing
    /// (`SessionLogger.livePaths`): the logger would go on appending to the
    /// file in the Trash, and Empty Trash would lose the rest of it.
    static func canTrash(_ entry: Entry, livePaths: Set<String>) -> Bool {
        !livePaths.contains(entry.url.standardizedFileURL.path)
    }

    /// `SessionLogger`'s name: "<session> yyyy-MM-dd HHmmss-XXXX.log".
    /// nil for a name that is not one of ours (it is still listed, by date).
    static func parse(_ fileName: String) -> (session: String, started: Date)? {
        parse(fileName, calendar: stampCalendar())
    }

    /// The calendar a stamp is read in: Gregorian, in the zone a new
    /// DateFormatter takes — `NSTimeZone.default` (the Mac's, unless the
    /// process set another; `TimeZone.current` would not follow that).
    static func stampCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        return calendar
    }

    /// `calendar` from `stampCalendar()`, made once per scan.
    static func parse(_ fileName: String, calendar: Calendar) -> (session: String, started: Date)? {
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
        guard let date = plainStampDate(stamp, calendar: calendar) ?? formatterStampDate(stamp, timeZone: calendar.timeZone)
        else { return nil }
        let session = String(before.dropLast())
        return session.isEmpty ? nil : (session, date)
    }

    /// The stamp as `DateFormatter` reads it — the rule, quirks and all:
    /// lenient (Feb 30 = Mar 2, hour 24 = the next midnight), a repeated hour
    /// = its later instant, a skipped one moved forward, any script's digits.
    /// A new formatter a call (1.4 s for 5,000 logs), so only what
    /// `plainStampDate` leaves comes here.
    static func formatterStampDate(_ stamp: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.date(from: stamp)
    }

    /// The stamp every log of ours has — ASCII "yyyy-MM-dd HHmmss", a real
    /// time this century, a day away from any change of the zone's offset —
    /// read digit by digit. nil = not that case, ask the formatter:
    /// anything out of range or rolled over, a skipped hour (the round trip
    /// differs) and a repeated one (Calendar takes the earlier instant, the
    /// formatter the later) all go there. `Tests/tests/LogLibraryTests.swift`
    /// holds the two to the same answer in 30 zones with every kind of change
    /// (checked against all 443 the Mac knows when this was written).
    static func plainStampDate(_ stamp: String, calendar: Calendar) -> Date? {
        let bytes = Array(stamp.utf8)
        guard bytes.count == 17, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: " ") else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for byte in bytes[start..<start + length] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(13, 2), let second = number(15, 2),
              (2000...2099).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second else { return nil }
        let zone = calendar.timeZone
        let offset = zone.secondsFromGMT(for: date)
        guard zone.secondsFromGMT(for: date.addingTimeInterval(-86_400)) == offset,
              zone.secondsFromGMT(for: date.addingTimeInterval(86_400)) == offset else { return nil }
        return date
    }

    /// Every `.log` in `directory`, newest first.
    static func scan(_ directory: URL, fileManager: FileManager = .default) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        let calendar = stampCalendar()
        return urls.compactMap { url -> Entry? in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            let modified = values.contentModificationDate ?? .distantPast
            let parsed = parse(url.lastPathComponent, calendar: calendar)
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

/// The Logs window's reads of the folder (6.1 (62)): off the main thread
/// (5,000 logs took 1.4 s on it before), applied on main. A request while a
/// read runs is served by ONE more read after it, so the last answer applied
/// always comes from a read begun after the last request — never a list from
/// before a delete or rename — and a burst of folder events costs two reads.
@MainActor
final class LogFolderReader {
    private var reading = false
    private var again = false
    private var latest: (directory: URL, apply: ([LogLibrary.Entry]) -> Void)?
    private let read: @Sendable (URL) -> [LogLibrary.Entry]
    /// Reads finished (the harness counts them).
    private(set) var reads = 0

    init(read: @escaping @Sendable (URL) -> [LogLibrary.Entry] = { LogLibrary.scan($0) }) {
        self.read = read
    }

    /// `apply` runs on main with the newest answer.
    func request(_ directory: URL, apply: @escaping ([LogLibrary.Entry]) -> Void) {
        latest = (directory, apply)
        guard !reading else { again = true; return }
        reading = true
        Task { await run() }
    }

    private func run() async {
        repeat {
            again = false
            guard let job = latest else { break }
            let (read, directory) = (read, job.directory)
            let found = await Task.detached(priority: .userInitiated) { read(directory) }.value
            reads += 1
            (latest?.apply ?? job.apply)(found)
        } while again
        reading = false
    }
}
