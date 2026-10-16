import Foundation

/// A web page while the left sidebar slides (5.0 (26)). WebKit repaints a
/// resize a frame or two late, so a page that narrowed or widened with
/// every frame of the slide drew its OLD width at the NEW place: the right
/// edge kicked in and back on close and ran off the tab on open (measured
/// frame by frame, 2026-10-16: 2929 → 2924 → 2875 → 2922 px). The right
/// panel never showed it because its page keeps its left edge and is
/// covered at the right.
///
/// So during the slide the page keeps ONE width, anchored to the tab's
/// RIGHT edge (which does not move), and the sidebar slides over / off its
/// left part (the tab clips it): opening keeps the old, wider page and it
/// narrows once when the slide ends; closing takes the new, wider width at
/// once. The right edge never moves; the page is resized once, not per frame.
nonisolated struct SidebarSlide: Equatable {
    /// Slightly longer than `AppModel.sidebarAnimation` (0.2 s).
    static let duration: TimeInterval = 0.26

    let width: Double
    /// The tab's width once the slide has settled.
    let target: Double
    let until: Date

    /// The page's width for the whole slide, from the tab's width when the
    /// slide starts and how much the sidebar takes (`delta`) — times `share`,
    /// the part of it that reaches this pane (`PaneLayout.widthShare`: a
    /// left/right split shares it; review 5.0 (26)). A slide still running
    /// (`previous`, a toggle within 0.26 s) is started from ITS target, not
    /// from a width caught mid-animation — the page keeps the width it has.
    static func start(tabWidth: Double, delta: Double, opening: Bool, share: Double = 1,
                      previous: SidebarSlide? = nil, now: Date = Date()) -> SidebarSlide {
        let change = delta * share
        let base = previous.flatMap { $0.isActive(now: now) ? $0.target : nil } ?? tabWidth
        let target = max(0, opening ? base - change : base + change)
        return SidebarSlide(width: max(0, opening ? base : target), target: target, until: now.addingTimeInterval(duration))
    }

    func isActive(now: Date = Date()) -> Bool { now < until }

    /// The page's x inside a tab of `tabWidth`: right edges together.
    func x(tabWidth: Double) -> Double { tabWidth - width }
}

extension Notification.Name {
    /// Posted BEFORE the sidebar's shown state changes (object: nil,
    /// userInfo "opening": Bool, "delta": Double).
    static let sheepSidebarWillSlide = Notification.Name("SheepTerm.sidebarWillSlide")
}
