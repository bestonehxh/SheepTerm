// SheepVTRender — the renderer-side half of the app's highlighter. (It replaced
// `SheepTerm/GridHighlighter.swift`, which was removed with SwiftTerm in 3.0.)
//
// The app owns the matcher (`Highlighter` + `HighlightScanner`); this file owns
// everything between the grid and the matcher: which rows form a paragraph, how
// a cell becomes one byte, and how the matcher's byte spans come back as a
// per-column foreground override for one row.
//
// Two things changed against `SheepTerm/GridHighlighter.swift` (ARCHITECTURE.md
// §5.2), both of them simplifications:
//
//  1. **Nothing is written into the grid.** `overrides(line:in:)` returns a
//     `cols`-long array of colour words; the row builder applies a word only
//     where `cell.fgSource == .default`, so "never clobber the device's colour"
//     is a two-bit compare instead of an owned-attribute set, and `strip()` /
//     `repaintAll()` / the 72 ms full-buffer stall are gone with it. Turning the
//     highlighter off is `enabled = false` plus a repaint.
//  2. **Rows are addressed by scroll-invariant line numbers** (`Buffer+Lines`),
//     so there is no `findBottom()` exponential probe and no renumbering hazard:
//     a line number means the same line for as long as the line exists, and a
//     line that fell off simply is not retained any more.
//
// What did NOT change — the rules the differential test forced (ARCHITECTURE.md
// §5.2 "กติกาที่ห้ามพัง"):
//
//  * a PARAGRAPH is matched, never a physical row (a 200-column banner wraps
//    `authorized` into `au` + `thorized` and neither half is a keyword), and the
//    whole paragraph, not the part that is on screen;
//  * the walk is bounded: ≤ 32 rows back to the head, ≤ 96 rows in total, so a
//    base64 blob wrapped into thousands of rows cannot turn one frame into a
//    linear scan of the scrollback;
//  * the last row is bounded by `trimmedLength` and right-trimmed (this is what
//    makes the cost track content instead of terminal width); earlier rows are
//    full width by definition — trimming them would fuse the words either side
//    of the wrap;
//  * every cell yields exactly ONE byte, so a byte offset is a column offset
//    (`rowIndex * cols + col`). A spacer repeats the byte of its wide head; a
//    non-ASCII cell becomes `_` when it is a letter or a number (a word
//    character no keyword contains: `中interface` must not match) and DEL
//    otherwise (`😀 up` must match); a combined cell classifies by its grapheme;
//  * the alternate screen gets nothing — a full-screen program owns its cells.

import SheepVT

/// One coloured run over a paragraph's bytes, as the app's matcher produces it.
///
/// `nonisolated` + `Sendable`: the matcher may live anywhere, only the overlay
/// is pinned to the main actor.
nonisolated public struct HighlightSpan: Equatable, Sendable {
    /// Byte range inside the paragraph handed to `HighlightProvider.spans(in:)`.
    public var range: Range<Int>
    /// 0xRRGGBB.
    public var rgb: UInt32
    public var bold: Bool

    public init(range: Range<Int>, rgb: UInt32, bold: Bool = false) {
        self.range = range
        self.rgb = rgb
        self.bold = bold
    }
}

/// The matcher, as the overlay sees it.
public protocol HighlightProvider: AnyObject {
    /// Spans over one paragraph of ASCII bytes (stand-ins for non-ASCII, see
    /// the file comment): byte range → colour.
    func spans(in paragraph: [UInt8]) -> [HighlightSpan]
    /// Bumped whenever the provider's rules change (a vendor switch): every
    /// cached row is stale.
    var revision: UInt64 { get }
}

/// Per-column foreground overrides for the rows the renderer is about to draw.
///
/// The unit of work is a paragraph: `overrides(line:)` builds the paragraph
/// containing `line` once and then serves every row of it from the cache, so a
/// screen of a wrapped banner costs one match, not one per row.
public final class HighlightOverlay {

    // MARK: - Encoding

    /// Set on every non-empty override word (so 0 can mean "no override" even
    /// for pure black).
    public static let presentBit: UInt32 = 0x8000_0000
    /// Bold flag inside an override word.
    public static let boldBit: UInt32 = 1 << 24
    /// 0xRRGGBB.
    public static let rgbMask: UInt32 = 0x00FF_FFFF

    /// Pack a colour word the way `overrides(line:in:)` returns it.
    public static func word(rgb: UInt32, bold: Bool) -> UInt32 {
        presentBit | (bold ? boldBit : 0) | (rgb & rgbMask)
    }

    // MARK: - Bounds (identical to GridHighlighter)

    /// How far back the head walk may go looking for the start of a paragraph.
    static let maxHeadWalk = 32
    /// How many rows one paragraph may span at most.
    static let maxParagraphRows = 96

    // MARK: - Public state

    public var provider: any HighlightProvider {
        didSet {
            guard provider !== oldValue else { return }
            invalidate()
        }
    }

    /// Off = `overrides` returns nil for every line. The renderer still has to
    /// repaint its rows when this changes; `revision` moves so a row cache keyed
    /// on it does that by itself.
    public var enabled = true {
        didSet { if enabled != oldValue { ownRevision &+= 1 } }
    }

    /// Bumped by `invalidate()`, by a provider swap, by `enabled`, and by a
    /// change of `provider.revision`. A row cache keyed on this value is
    /// dropped exactly when this overlay's output can differ.
    public var revision: UInt64 {
        syncProviderRevision()
        return ownRevision
    }

    private var ownRevision: UInt64 = 1
    private var lastProviderRevision: UInt64

    public init(provider: any HighlightProvider) {
        self.provider = provider
        self.lastProviderRevision = provider.revision
    }

    // MARK: - Cache

    /// One matched paragraph. Valid while every member row still has the
    /// generation it had when the bytes were read, the paragraph has not grown
    /// a new continuation row, the width is unchanged and the provider's rules
    /// have not moved.
    private struct Entry {
        /// Line number of the paragraph's first row.
        var head: Int
        /// Per member row: `Row.generation`, or `noRow` for a row that has never
        /// been materialised (a blank line — `Buffer.row(line:)` returns nil).
        var generations: [UInt64]
        /// Per member row: which `Row` object it was. A region scroll moves
        /// row references between line numbers without changing how many
        /// times each was written, so generations alone can match a row that
        /// is no longer on that line.
        var identities: [ObjectIdentifier?]
        /// Per member row: `cols` override words.
        var rows: [[UInt32]]
        var cols: Int
        var providerRevision: UInt64
        /// True when the walk stopped because it hit `maxParagraphRows`, in
        /// which case a wrapped row after the last member is expected and must
        /// not be read as "the paragraph grew".
        var truncated: Bool
    }

    /// A row that has never been materialised: blank, and not a continuation.
    private static let noRow = UInt64.max

    private var entries: [Int: Entry] = [:]        // head line → entry
    private var headOfLine: [Int: Int] = [:]       // member line → head line
    /// The line the last call asked about; cache trimming is measured from here.
    private var lastAskedLine = 0

    // MARK: - Invalidation

    /// Drop everything (resize, clear, reset) and move `revision`.
    public func invalidate() {
        entries.removeAll(keepingCapacity: true)
        headOfLine.removeAll(keepingCapacity: true)
        lastProviderRevision = provider.revision
        ownRevision &+= 1
    }

    private func syncProviderRevision() {
        let r = provider.revision
        guard r != lastProviderRevision else { return }
        entries.removeAll(keepingCapacity: true)
        headOfLine.removeAll(keepingCapacity: true)
        lastProviderRevision = r
        ownRevision &+= 1
    }

    // MARK: - The one public query

    /// Foreground overrides for `line`: `cols` entries, 0 = none, else
    /// `0x8000_0000 | bold << 24 | rgb`.
    ///
    /// nil when the overlay is off, on the alternate screen, or when `line` is
    /// not retained by the buffer. A retained line that has never been written
    /// is blank, not nil: it gets an array of zeros like any other unmatched row.
    public func overrides(line: Int, in terminal: Terminal) -> [UInt32]? {
        guard enabled else { return nil }
        guard !terminal.isAlternate else { return nil }
        syncProviderRevision()

        let buffer = terminal.buffer
        guard buffer.hasLine(line) else { return nil }
        let cols = terminal.cols
        guard cols > 0 else { return nil }
        lastAskedLine = line

        // Cache hit: this line is a member of a paragraph we already matched.
        if let head = headOfLine[line], let entry = entries[head] {
            let index = line - head
            if index >= 0, index < entry.rows.count, entry.cols == cols,
               entry.providerRevision == lastProviderRevision,
               isFresh(entry, in: buffer) {
                return entry.rows[index]
            }
            // Anything stale takes the whole paragraph with it — the rows share
            // one byte stream, so one changed row can change every row's spans.
            drop(head: head)
        }

        guard let entry = build(paragraphContaining: line, in: buffer, cols: cols) else { return nil }
        store(entry)
        trim(rows: terminal.rows)
        let index = line - entry.head
        guard index >= 0, index < entry.rows.count else { return nil }
        return entry.rows[index]
    }

    // MARK: - Cache bookkeeping

    private func isFresh(_ entry: Entry, in buffer: Buffer) -> Bool {
        for (i, generation) in entry.generations.enumerated() {
            let l = entry.head + i
            guard buffer.hasLine(l) else { return false }
            let row = buffer.row(line: l)
            if (row?.generation ?? Self.noRow) != generation { return false }
            if entry.identities.count > i, entry.identities[i] != row.map(ObjectIdentifier.init) { return false }
        }
        // A paragraph that grew a continuation row after the ones we read: the
        // new row's bytes belong to this byte stream.
        if !entry.truncated {
            let after = entry.head + entry.generations.count
            if buffer.hasLine(after), buffer.row(line: after)?.wrapped == true { return false }
        }
        return true
    }

    private func store(_ entry: Entry) {
        entries[entry.head] = entry
        for i in 0..<entry.rows.count { headOfLine[entry.head + i] = entry.head }
    }

    private func drop(head: Int) {
        guard let entry = entries.removeValue(forKey: head) else { return }
        for i in 0..<entry.rows.count where headOfLine[head + i] == head {
            headOfLine[head + i] = nil
        }
    }

    /// Keep roughly four screens of rows around the last line asked about; the
    /// renderer walks a viewport at a time, so anything further away is either
    /// scrollback the user left behind or output that has moved on.
    private func trim(rows: Int) {
        let keep = Swift.max(rows * 4, Self.maxParagraphRows * 2)
        var doomed: [Int] = []
        for (head, entry) in entries {
            let last = head + entry.rows.count - 1
            if head - lastAskedLine > keep || lastAskedLine - last > keep { doomed.append(head) }
        }
        for head in doomed { drop(head: head) }
    }

    // MARK: - Building one paragraph

    /// The member lines of the paragraph containing `line`, bounded both ways.
    /// Also reports whether the forward walk was cut short by the row cap.
    private func paragraph(containing line: Int, in buffer: Buffer) -> (lines: [Int], truncated: Bool) {
        // Back to the head: a row flagged `wrapped` continues the row above it.
        // The first retained line can itself be wrapped (the row it continued
        // fell off the top), which is where the walk stops.
        var head = line
        var walked = 0
        while walked < Self.maxHeadWalk,
              buffer.row(line: head)?.wrapped == true,
              buffer.hasLine(head - 1) {
            head -= 1
            walked += 1
        }
        var lines = [head]
        var next = head + 1
        while lines.count < Self.maxParagraphRows,
              buffer.hasLine(next),
              buffer.row(line: next)?.wrapped == true {
            lines.append(next)
            next += 1
        }
        let truncated = lines.count == Self.maxParagraphRows
        return (lines, truncated)
    }

    /// Stands in for a cell whose character is not ASCII.
    ///
    /// The matcher maps byte offsets onto COLUMNS and every cell is one column
    /// whatever it holds, so the row keeps its shape as long as each cell yields
    /// exactly one byte. What the byte has to get right is the WORD BOUNDARY: a
    /// Thai or CJK letter is `\w`, so `中interface` must not match; an emoji or a
    /// symbol is not, so `😀up` must. `_` is a word character no keyword contains
    /// and no matcher starts on; DEL is neither word, digit, hex, blank nor
    /// separator to any of them.
    @inline(__always)
    static func placeholder(for ch: Character) -> UInt8 {
        ch.isLetter || ch.isNumber ? 0x5F : 0x7F
    }

    private func build(paragraphContaining line: Int, in buffer: Buffer, cols: Int) -> Entry? {
        let (lines, truncated) = paragraph(containing: line, in: buffer)

        var generations = [UInt64](repeating: Self.noRow, count: lines.count)
        var identities = [ObjectIdentifier?](repeating: nil, count: lines.count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(cols * lines.count)

        for (index, l) in lines.enumerated() {
            let isLast = index == lines.count - 1
            guard let row = buffer.row(line: l) else {
                // Never materialised = blank. A blank row in the middle of a
                // paragraph still owes its full width of columns, or every byte
                // after it would be off by `cols`.
                if !isLast { bytes.append(contentsOf: repeatElement(0x20, count: cols)) }
                continue
            }
            generations[index] = row.generation
            identities[index] = ObjectIdentifier(row)
            // The byte↔column map this whole method depends on assumes the row
            // is exactly `cols` wide. It always is; bail rather than trust that
            // through a future resize edge (and do not cache the result).
            guard row.cols == cols else { return nil }

            // Only the LAST row of a paragraph may be bounded early: an earlier
            // row is full by definition — that is why it wrapped — and trimming
            // it would fuse the words either side of the break. Bounding the
            // last row by `trimmedLength` is what makes the cost track content
            // instead of terminal width.
            let limit = isLast ? Swift.min(row.trimmedLength, cols) : cols
            var rowBytes = [UInt8](repeating: 0x20, count: limit)
            let cells = row.cells
            for col in 0..<limit {
                let cell = cells[col]
                if cell.isCombined, let s = row.combinedString(at: col), let ch = s.first {
                    // A grapheme cluster is one column too, so also one byte —
                    // classified by the whole cluster, not its base scalar.
                    rowBytes[col] = Self.placeholder(for: ch)
                } else if cell.code == 0 {
                    // Untouched cells hold NUL, not space — and so does the
                    // spacer after a wide character, which is the second column
                    // of THAT character, not a blank between it and the next.
                    rowBytes[col] = (col > 0 && cells[col - 1].width == 2) ? rowBytes[col - 1] : 0x20
                } else if cell.code < 0x80 {
                    rowBytes[col] = UInt8(cell.code)
                } else {
                    // A real non-ASCII scalar (Thai, CJK, latin-1). One cell,
                    // one column, one stand-in byte — skipping the row here
                    // used to lose the colour on every ASCII token of a banner
                    // that merely contained one.
                    rowBytes[col] = Self.placeholder(for: Character(Unicode.Scalar(cell.code) ?? "\u{FFFD}"))
                }
            }
            if isLast { while rowBytes.last == 0x20 { rowBytes.removeLast() } }
            bytes.append(contentsOf: rowBytes)
        }

        // Work out what every column of the paragraph should carry in one pass:
        // an override that stops applying disappears by itself, which is what a
        // vendor switch needs (the old apply-only loop could add colour but
        // never take it away).
        var target = [UInt32](repeating: 0, count: bytes.count)
        if !bytes.isEmpty {
            for span in provider.spans(in: bytes) {
                let word = Self.word(rgb: span.rgb, bold: span.bold)
                let lo = Swift.max(span.range.lowerBound, 0)
                let hi = Swift.min(span.range.upperBound, target.count)
                guard lo < hi else { continue }
                for offset in lo..<hi { target[offset] = word }
            }
        }

        // Slice the span map back into rows. A blank paragraph is cached too —
        // returning without recording it made every blank row re-match on every
        // frame.
        var rows = [[UInt32]]()
        rows.reserveCapacity(lines.count)
        for index in 0..<lines.count {
            let base = index * cols
            if base >= target.count {
                rows.append([UInt32](repeating: 0, count: cols))
                continue
            }
            let end = Swift.min(base + cols, target.count)
            var out = [UInt32](repeating: 0, count: cols)
            for i in base..<end where target[i] != 0 { out[i - base] = target[i] }
            rows.append(out)
        }

        return Entry(head: lines[0], generations: generations, identities: identities, rows: rows,
                     cols: cols, providerRevision: lastProviderRevision, truncated: truncated)
    }
}
