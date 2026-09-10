// SheepVT — a cell address that survives scrolling.
//
// Selection and search never store buffer indices: the ring recycles rows and
// every line that leaves the top of the scrollback shifts every index down by
// one. They store the **scroll-invariant line number** instead
// (`LineRing.trimmed + index`, the same idea GridHighlighter uses in the app),
// so a position stays valid for as long as its line is retained and becomes
// detectably stale — never silently wrong — once the line falls off.

/// One cell, addressed by scroll-invariant line number and column.
///
/// `Comparable` is reading order: line first, then column. A `Position` says
/// nothing about which buffer it belongs to; hosts drop their positions on a
/// buffer switch and on a resize (reflow renumbers lines arbitrarily).
public struct Position: Equatable, Hashable, Comparable, Sendable {
    /// Scroll-invariant line number (`Buffer.lineNumber(atIndex:)`).
    public var line: Int
    /// 0-based cell column.
    public var col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }

    public static func < (a: Position, b: Position) -> Bool {
        a.line != b.line ? a.line < b.line : a.col < b.col
    }
}
