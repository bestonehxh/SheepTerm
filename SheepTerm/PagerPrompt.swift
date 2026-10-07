import Foundation

/// The `--More--` family: what a network device prints when a page of output
/// is full and it is waiting for a key. Auto-page (View → Auto-page) answers
/// it with a space so a long `show` runs to the end on its own.
///
/// Pure and `nonisolated`: compiled into `Tests/run.sh tests` and exercised
/// on real pager strings there. The controller feeds it every chunk it drains
/// into the terminal and sends a space when it says so.
nonisolated enum PagerPrompt {
    /// Prompt tails, compared case-insensitively against the end of the
    /// chunk after trailing blanks, carriage returns, backspaces and escape
    /// sequences are removed. The Junos form carries a percentage and is
    /// matched by shape (`---(more` … `)---`) in `endsWithPrompt`.
    static let tails: [String] = [
        "--more--",                 // Cisco IOS/IOS-XE/NX-OS, FortiOS, Gaia
        "-- more --",               // Aruba CX (`-- MORE --, next page: Space, …`)
        "--more-- or (q)uit",       // ArubaOS
        "---- more ----",           // Huawei VRP, Comware
        "--more-- (press space",    // older Comware
        "press any key to continue",
    ]

    /// Longest tail worth looking at: the longest prompt plus the escape
    /// sequences and blanks a device wraps it in.
    static let window = 160

    /// True when `bytes` end with a pager prompt. Only the END counts: the
    /// same words in the middle of a page are text, not a prompt.
    static func endsWithPrompt(_ bytes: [UInt8]) -> Bool {
        let tail = cleanedTail(bytes)
        guard !tail.isEmpty else { return false }
        for prompt in tails where hasSuffix(tail, Array(prompt.utf8)) { return true }
        // Junos: `---(more 15%)---` / `---(more)---`.
        if hasSuffix(tail, Array(")---".utf8)), contains(tail, Array("---(more".utf8)) { return true }
        // Aruba CX writes the key legend after the prompt on the same line.
        if contains(tail, Array("-- more --, next page".utf8)) { return true }
        return false
    }

    // MARK: - internals

    /// The last `window` bytes, lower-cased ASCII, with every escape sequence
    /// removed and trailing blanks / CR / backspaces stripped. A chunk that
    /// ends in the middle of an escape sequence keeps the partial sequence
    /// out of the comparison too.
    static func cleanedTail(_ bytes: [UInt8]) -> [UInt8] {
        let start = Swift.max(0, bytes.count - window)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count - start)
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                // ESC [ … final (CSI), ESC ] … BEL/ST (OSC), or ESC + one byte.
                i += 1
                guard i < bytes.count else { break }
                switch bytes[i] {
                case 0x5B:   // [
                    i += 1
                    while i < bytes.count, bytes[i] < 0x40 { i += 1 }
                    i += 1
                case 0x5D:   // ]
                    i += 1
                    while i < bytes.count, bytes[i] != 0x07, bytes[i] != 0x1B { i += 1 }
                    if i < bytes.count, bytes[i] == 0x1B { i += 1 }   // ESC \
                    i += 1
                default:
                    i += 1
                }
                continue
            }
            // Lower-case ASCII letters; everything else as is.
            out.append(b >= 0x41 && b <= 0x5A ? b + 0x20 : b)
            i += 1
        }
        while let last = out.last, last == 0x20 || last == 0x0D || last == 0x0A || last == 0x08 || last == 0x09 {
            out.removeLast()
        }
        return out
    }

    private static func hasSuffix(_ bytes: [UInt8], _ suffix: [UInt8]) -> Bool {
        guard bytes.count >= suffix.count else { return false }
        return bytes[(bytes.count - suffix.count)...].elementsEqual(suffix)
    }

    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }
}

/// Per-session pager detector: joins the end of the previous chunk to the
/// start of the next (a prompt split across two reads is still a prompt) and
/// caps how often it answers, so a device that re-prints its prompt on every
/// space cannot be driven into a loop.
nonisolated struct PagerDetector {
    /// Answers per second, at most. A real page takes far longer than 20 ms
    /// to arrive; a device answering a space with the same prompt at once is
    /// the loop this guards against.
    static let maxPerSecond = 50

    private var tail: [UInt8] = []
    private var windowStart: TimeInterval = 0
    private var answered = 0

    init() {}

    /// Feed one chunk as it is drained into the terminal. Returns true when
    /// the caller should send a space.
    mutating func consume(_ bytes: [UInt8], now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        guard !bytes.isEmpty else { return false }
        var joined = tail
        joined.append(contentsOf: bytes)
        if joined.count > PagerPrompt.window { joined.removeFirst(joined.count - PagerPrompt.window) }
        tail = joined
        guard PagerPrompt.endsWithPrompt(joined) else { return false }
        // The prompt was answered (or refused): whatever comes next starts
        // a new page, and the same prompt bytes must not count twice.
        tail.removeAll(keepingCapacity: true)
        if now - windowStart >= 1 {
            windowStart = now
            answered = 0
        }
        answered += 1
        return answered <= PagerDetector.maxPerSecond
    }
}
