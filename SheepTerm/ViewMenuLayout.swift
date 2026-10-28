import Foundation

// The View menu (6.0 (12), structure approved by the user 2026-10-29): one
// flat list of ~30 items became a few submenus. `SheepTermCommands` builds
// the SwiftUI menu in THIS order and takes every keyboard shortcut from
// `shortcut(_:webSelected:)` — so the harness (ViewMenuTests) can check that
// every item is there exactly once, in its submenu, and that no shortcut
// moved or collides. Key equivalents inside a submenu still fire: AppKit's
// performKeyEquivalent walks submenus (Font ▸ Bigger ⌘= always lived in one).
//
// macOS adds its own items to View (Enter Full Screen …); they are not ours
// and stay where the system puts them.
nonisolated enum ViewMenuLayout {
    enum Item: String, CaseIterable, Sendable {
        case toggleSidebar
        // Sidebar ▸
        case sidebarAtLaunch, groupColors, reorderGroups, addHosts
        // Terminal ▸
        case toggleHighlighting, autoPage, deviceFamily, clearScrollback, theme, font
        // Terminal ▸ Font ▸ (the rest of Font is the family/weight lists)
        case fontBigger, fontSmaller
        // Web ▸
        case openLocation, reloadPage, back, forward, clearWebsiteData
        // AI ▸
        case showAIPanel, aiAssistant
        // Bottom Bar ▸
        case showBottomBar, connectionStatus, sessionInfo, shortcutHints, thisMacIP, clock, fileServer, transferProgress
        case networkInfo

        /// The English title as written in SheepTermCommands (the catalog key).
        var title: String {
            switch self {
            case .toggleSidebar: "Toggle Sidebar"
            case .sidebarAtLaunch: "Show Sidebar at Launch"
            case .groupColors: "Group Colors"
            case .reorderGroups: "Reorder Groups…"
            case .addHosts: "Add Hosts…"
            case .toggleHighlighting: "Toggle Highlighting"
            case .autoPage: "Auto-page (--More--)"
            case .deviceFamily: "Device Family"
            case .clearScrollback: "Clear Scrollback"
            case .theme: "Theme"
            case .font: "Font"
            case .fontBigger: "Bigger"
            case .fontSmaller: "Smaller"
            case .openLocation: "Open Location"
            case .reloadPage: "Reload Page"
            case .back: "Back"
            case .forward: "Forward"
            case .clearWebsiteData: "Clear Website Data…"
            case .showAIPanel: "Show AI Panel"
            case .aiAssistant: "AI Assistant"
            case .showBottomBar: "Show Bottom Bar"
            case .connectionStatus: "Connection Status"
            case .sessionInfo: "Session Info"
            case .shortcutHints: "Shortcut Hints"
            case .thisMacIP: "This Mac IP"
            case .clock: "Clock"
            case .fileServer: "File Server"
            case .transferProgress: "Transfer Progress"
            case .networkInfo: "Network Info…"
            }
        }
    }

    indirect enum Node: Equatable, Sendable {
        case item(Item)
        /// A submenu: its English title (catalog key) and what is in it.
        /// `Item.theme` / `Item.font` are submenus whose lists are data
        /// (themes, font families), so they appear as `.item`/`.submenu`
        /// with only their fixed entries.
        case submenu(String, [Node])
    }

    static let tree: [Node] = [
        .item(.toggleSidebar),
        .submenu("Sidebar", [.item(.sidebarAtLaunch), .item(.groupColors), .item(.reorderGroups), .item(.addHosts)]),
        .submenu("Terminal", [
            .item(.toggleHighlighting), .item(.autoPage), .item(.deviceFamily), .item(.clearScrollback),
            .item(.theme),
            .submenu("Font", [.item(.fontBigger), .item(.fontSmaller)]),
        ]),
        .submenu("Web", [.item(.openLocation), .item(.reloadPage), .item(.back), .item(.forward), .item(.clearWebsiteData)]),
        .submenu("AI", [.item(.showAIPanel), .item(.aiAssistant)]),
        .submenu("Bottom Bar", [
            .item(.showBottomBar), .item(.connectionStatus), .item(.sessionInfo), .item(.shortcutHints),
            .item(.thisMacIP), .item(.clock), .item(.fileServer), .item(.transferProgress),
        ]),
        .item(.networkInfo),
    ]

    /// The Font submenu IS the `font` item: the tree names it by title.
    static let submenuItems: [String: Item] = ["Font": .font]

    enum Modifier: String, Sendable, Comparable {
        case command, shift, option, control
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    struct Shortcut: Equatable, Hashable, Sendable {
        /// One character ("0", "l", "[") or a named key ("return").
        let key: String
        let modifiers: Set<Modifier>
    }

    /// Every shortcut the View menu has — the same keys it had before the
    /// regroup. ⌘L has ONE owner at a time (it always had): the web tab's
    /// Open Location on a web tab, Clear Scrollback everywhere else.
    static func shortcut(_ item: Item, webSelected: Bool) -> Shortcut? {
        switch item {
        case .toggleSidebar: Shortcut(key: "0", modifiers: [.command])
        case .showAIPanel: Shortcut(key: "a", modifiers: [.command, .option])
        case .toggleHighlighting: Shortcut(key: "h", modifiers: [.command, .shift])
        case .clearScrollback: webSelected ? nil : Shortcut(key: "l", modifiers: [.command])
        case .openLocation: webSelected ? Shortcut(key: "l", modifiers: [.command]) : nil
        case .reloadPage: Shortcut(key: "r", modifiers: [.command])
        case .back: Shortcut(key: "[", modifiers: [.command])
        case .forward: Shortcut(key: "]", modifiers: [.command])
        case .networkInfo: Shortcut(key: "i", modifiers: [.command, .option])
        case .fontBigger: Shortcut(key: "=", modifiers: [.command])
        case .fontSmaller: Shortcut(key: "-", modifiers: [.command])
        default: nil
        }
    }

    /// Items in menu order, depth first (a submenu named in `submenuItems`
    /// counts as that item, in its place).
    static var flattened: [Item] {
        func walk(_ nodes: [Node]) -> [Item] {
            nodes.flatMap { node -> [Item] in
                switch node {
                case .item(let item): [item]
                case .submenu(let title, let children): (submenuItems[title].map { [$0] } ?? []) + walk(children)
                }
            }
        }
        return walk(tree)
    }

    /// Titles in the order the source writes them: submenu titles and item
    /// titles, depth first.
    static var titlesInOrder: [String] {
        func walk(_ nodes: [Node]) -> [String] {
            nodes.flatMap { node -> [String] in
                switch node {
                case .item(let item): [item.title]
                case .submenu(let title, let children): [title] + walk(children)
                }
            }
        }
        return walk(tree)
    }
}
