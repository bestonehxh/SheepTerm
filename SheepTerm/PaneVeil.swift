import CoreGraphics

/// The connection card's veil over a whole pane (6.0 (12)).
///
/// The card's 45 % black veil (`ConnectionOverlayView`) is a subview of the
/// TERMINAL view, so it ends at the terminal's edge — and a lone terminal
/// pane sits 10 pt in from the window sides and 6 pt down (Terminal.app's
/// margin, ARCHITECTURE.md §32), a split card's terminal 10 pt in from the
/// card's sides. Those strips stayed at full brightness around the dimmed
/// terminal: a lighter frame round every connecting pane (the user: "why is
/// there a black border through a jump host" — the hop just made the Connect
/// stage last long enough to notice). The pane tree now owns the lone
/// pane's margin too (it was DetailPane's padding, outside the tree) and
/// paints the same veil on every strip between the pane's area and its
/// terminal; the header row of a split card stays bright, as the card's
/// title / × are not under the card.
///
/// It also holds the split look's numbers (D3, 6.0 (12) integration of
/// pane-grid): `PaneTreeView`, `PaneLeafView` and `PaneHeaderView` read them
/// from here so the veil's strips and the cards are cut from ONE geometry
/// (and the harness can check it — AppKit views are not in it).
nonisolated enum PaneVeil {
    /// The split look "D3" (the user chose it from mockups, 2026-10-28),
    /// ≥ 2 panes only: cards 5 pt apart and 5 pt in from the tree's edges on a
    /// near-black backdrop, rounded 8, a 1 px inner border, a 24 pt
    /// transparent header row at the top of each card.
    enum D3 {
        static let gap: CGFloat = 5
        static let margin: CGFloat = 5
        static let headerHeight: CGFloat = 24
        static let cornerRadius: CGFloat = 8
        static let border: CGFloat = 1
    }

    /// A lone (or zoomed) terminal pane's margin inside the tree: top, left,
    /// bottom, right — the numbers DetailPane used to pad with.
    struct Margin: Equatable {
        var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
        static let zero = Margin(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Terminal.app's: 10 pt each side, 6 on top (measured, 5.0 (54)).
    static let terminalMargin = Margin(top: 6, left: 10, bottom: 0, right: 10)

    /// D3's 5 pt round the split cards.
    static let splitMargin = Margin(top: D3.margin, left: D3.margin, bottom: D3.margin, right: D3.margin)

    /// The tree's margin round its panes: a lone or zoomed terminal gets
    /// Terminal.app's; a lone / zoomed web / Files / Ping pane fills the area;
    /// split cards sit D3's 5 pt in from every edge (their text inset is the
    /// card's own).
    static func margin(paneCount: Int, zoomed: Bool, visibleIsTerminal: Bool) -> Margin {
        if paneCount == 1 || zoomed { return visibleIsTerminal ? terminalMargin : .zero }
        return splitMargin
    }

    /// Inside one pane of `size` (own coordinates, y down): the header row
    /// (nil without one) and where the terminal / web view goes. A split card
    /// (`headed`) keeps its 1 px border clear on the sides and bottom and its
    /// 24 pt header on top; `left` / `right` are the terminal's room inside
    /// the border (`PaneTreeView.paneTextInset`, 0 for a web pane).
    static func cardLayout(size: CGSize, headed: Bool, left: CGFloat = 0, right: CGFloat = 0) -> (header: CGRect?, content: CGRect) {
        let edge = headed ? D3.border : 0
        let top = headed ? D3.headerHeight : 0
        let content = CGRect(x: left + edge, y: top,
                             width: max(0, size.width - left - right - 2 * edge),
                             height: max(0, size.height - top - edge))
        return (headed ? CGRect(x: 0, y: 0, width: size.width, height: D3.headerHeight) : nil, content)
    }

    /// `rect` with the margin taken off its sides (never negative).
    static func inset(_ rect: CGRect, by margin: Margin) -> CGRect {
        CGRect(x: rect.minX + margin.left, y: rect.minY + margin.top,
               width: max(0, rect.width - margin.left - margin.right),
               height: max(0, rect.height - margin.top - margin.bottom))
    }

    /// `rect` grown by the margin (the area a lone pane's veil covers).
    static func outset(_ rect: CGRect, by margin: Margin) -> CGRect {
        CGRect(x: rect.minX - margin.left, y: rect.minY - margin.top,
               width: rect.width + margin.left + margin.right,
               height: rect.height + margin.top + margin.bottom)
    }

    /// The strips of `area` the terminal's own veil does not reach: `area`
    /// minus `terminal`, minus the header row (`header`, a full-width band,
    /// stays bright). In `area`'s own coordinates (origin = its top-left,
    /// y down), empty ones dropped. Left and right run the full height so the
    /// corners are covered once; top and bottom only span the terminal.
    static func strips(area: CGRect, terminal: CGRect, header: CGRect? = nil) -> [CGRect] {
        let term = terminal.intersection(area)
        guard !term.isNull, !term.isEmpty else { return subtract(header, from: [area]).map { local($0, in: area) } }
        let pieces = [
            CGRect(x: area.minX, y: area.minY, width: term.minX - area.minX, height: area.height),
            CGRect(x: term.maxX, y: area.minY, width: area.maxX - term.maxX, height: area.height),
            CGRect(x: term.minX, y: area.minY, width: term.width, height: term.minY - area.minY),
            CGRect(x: term.minX, y: term.maxY, width: term.width, height: area.maxY - term.maxY),
        ]
        return subtract(header, from: pieces).map { local($0, in: area) }
    }

    private static func local(_ rect: CGRect, in area: CGRect) -> CGRect {
        rect.offsetBy(dx: -area.minX, dy: -area.minY)
    }

    /// Each rect minus `band` (the header row): what is above and below it,
    /// and beside it where the band is narrower than the rect (a zoomed
    /// card's header sits inside the margin, which is veiled beside it).
    private static func subtract(_ band: CGRect?, from rects: [CGRect]) -> [CGRect] {
        rects.flatMap { rect -> [CGRect] in
            guard rect.width > 0, rect.height > 0 else { return [] }
            guard let band, rect.intersects(band) else { return [rect] }
            let cut = rect.intersection(band)
            return [
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
            ].filter { $0.width > 0 && $0.height > 0 }
        }
    }
}
