import AppKit

/// "Open Link in New Tab" in a web tab's context menu (5.0 (25)): WebKit's
/// own "Open Link in New Window" item, retitled — its target, action and
/// `representedObject` are left exactly as WebKit made them (WebKit's
/// `forwardContextMenuAction:` reads `representedObject` as its own wrapper;
/// replacing it killed the app — review 5.0 (25) #1). The pick is noticed
/// through `NSMenu.willSendActionNotification`, which arrives before WebKit
/// asks for a new web view (`createWebViewWith`), so that call knows to open
/// a tab instead of loading in place.
@MainActor final class WebNewTabMenu {
    static let itemID = "WKMenuItemIdentifierOpenLinkInNewWindow"
    static let title = "Open Link in New Tab"
    private var observers: [NSObjectProtocol] = []

    /// Retitles the item in `menu` (if there is one) and calls `onPick` when
    /// it is the item chosen. The watch ends when the menu closes.
    func prepare(_ menu: NSMenu, onPick: @escaping @MainActor () -> Void) {
        end()
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == Self.itemID }) else { return }
        item.title = Self.title
        let center = NotificationCenter.default
        let target = ObjectIdentifier(item)
        observers.append(center.addObserver(forName: NSMenu.willSendActionNotification, object: menu, queue: nil) { note in
            let hit = (note.userInfo?["MenuItem"] as? NSMenuItem).map(ObjectIdentifier.init) == target
            MainActor.assumeIsolated { if hit { onPick() } }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil) { [weak self] _ in
            // DEFERRED, never synchronous: a real pick ends tracking FIRST and
            // sends the action ~1 ms later in the same call stack (measured,
            // review 5.0 (25) round 2) — ending here would miss the pick.
            MainActor.assumeIsolated { DispatchQueue.main.async { self?.end() } }
        })
    }

    // `end()` is called when a menu ends; a view freed mid-menu leaves only
    // observers filtered to a dead menu (harmless).
    func end() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// The mark "the next new-web-view request is the context menu's Open Link
/// in New Tab": taken once, and only shortly after the pick — a pick WebKit
/// never turned into a request (a mailto: link, a refused URL) must not make
/// a later target=_blank open a tab.
struct WebNewTabMark {
    static let lifetime: TimeInterval = 1
    private var at: Date?

    mutating func set(now: Date = Date()) { at = now }
    mutating func clear() { at = nil }
    mutating func take(now: Date = Date()) -> Bool {
        defer { at = nil }
        guard let at else { return false }
        return now.timeIntervalSince(at) <= Self.lifetime && now >= at
    }
}
