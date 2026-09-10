// SheepVT — scroll-invariant line numbering.
//
// The ring indexes lines 0..<count with 0 being the oldest *retained* line, so
// an index means something different after every line that falls off the top.
// A **line number** is `LineRing.trimmed + index`: it is assigned once, when the
// line is produced, and never changes for as long as the line exists. Selection
// (`Selection`) and search (`SearchEngine`) address the grid this way.
//
// Everything here is a reader: it never materialises a lazily-empty row. A row
// that has never been written is blank and not wrapped, and `row(line:)`
// returns nil for it exactly as it does for a line that has fallen off — the
// callers here treat both as "blank, not a continuation".

extension Buffer {
    /// Scroll-invariant number of the line at absolute ring index `index`.
    /// Defined for any index; only `0..<lines.count` is currently retained.
    public func lineNumber(atIndex index: Int) -> Int { lines.trimmed + index }

    /// Ring index for a line number, or nil once the line has fallen off the
    /// top of the scrollback (or has not been produced yet).
    public func index(ofLine line: Int) -> Int? {
        let i = line - lines.trimmed
        return (i >= 0 && i < lines.count) ? i : nil
    }

    /// Line number of a screen row (row 0 = the top of the screen).
    public func lineNumber(ofScreenRow row: Int) -> Int { lineNumber(atIndex: ybase + row) }

    /// Line number of a viewport row (row 0 = the top of what the user sees,
    /// which is the top of the screen unless they scrolled back).
    public func lineNumber(ofViewportRow row: Int) -> Int { lineNumber(atIndex: ydisp + row) }

    /// The row holding `line` without allocating: nil when the line has fallen
    /// off, is not yet produced, or has never been materialised (= blank).
    public func row(line: Int) -> Row? {
        guard let i = index(ofLine: line) else { return nil }
        return lines.allocatedRow(at: i)
    }

    // MARK: - the retained range

    /// Number of lines currently retained (scrollback + screen).
    public var lineCount: Int { lines.count }

    /// Number of the oldest retained line (`lines.trimmed`).
    public var firstLine: Int { lines.trimmed }

    /// Number of the newest retained line. Equals `firstLine - 1` when the
    /// buffer somehow holds no lines at all.
    public var lastLine: Int { lines.trimmed + lines.count - 1 }

    /// Is this line still retained?
    public func hasLine(_ line: Int) -> Bool { index(ofLine: line) != nil }

    /// Clamp a line number into the retained range.
    public func clampLine(_ line: Int) -> Int {
        Swift.min(Swift.max(line, firstLine), Swift.max(lastLine, firstLine))
    }

    // MARK: - logical lines

    /// True when `line` is a soft continuation of the line above it.
    public func isWrapped(line: Int) -> Bool {
        guard line > firstLine else { return false }   // nothing above to continue
        return row(line: line)?.wrapped ?? false
    }

    /// A logical line is a row plus every following row whose `wrapped` flag is
    /// set. Returns the first and last line number of the logical line
    /// containing `line` (clamped into the retained range).
    ///
    /// Note the first retained line can itself carry `wrapped` — the row it
    /// continued has fallen off the top — so the backward walk stops at
    /// `firstLine` and the logical line is simply the visible remainder.
    public func logicalLine(containing line: Int) -> ClosedRange<Int> {
        let l = clampLine(line)
        var lo = l
        while lo > firstLine, row(line: lo)?.wrapped == true { lo -= 1 }
        var hi = l
        while hi < lastLine, row(line: hi + 1)?.wrapped == true { hi += 1 }
        return lo...hi
    }
}
