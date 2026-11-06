import Foundation

/// Help ▸ SheepTerm Guide (6.1, the user: "a manual with the real UI — right-
/// click, Optimize, new connections — not just Add Host"). One topic per
/// page: a few steps and, where it helps, a real picture of the app (the
/// shots build, sample data only — `Manual-*`, or the `WhatsNew-*` it shares). Pure:
/// the harness checks every picture is in the catalog and every string is
/// translated (`Tests/tests/ManualTests.swift`).
nonisolated enum ManualPlan {
    struct Topic: Identifiable, Equatable, Sendable {
        let id: String
        let symbol: String
        let title: String
        let steps: [String]
        /// An image in the asset catalog; nil = text only.
        let picture: String?
    }

    static let topics: [Topic] = [
        Topic(id: "home", symbol: "house", title: "Home", steps: [
            "Click the house at the start of the tab bar, or View ▸ Home (⇧⌘0).",
            "One click picks a host; a double-click connects.",
            "Edit Home picks the widgets — Recent, a group, hosts by type — in 1, 2 or 3 columns.",
            "Add Host, Add Hosts, New Group, Add Credential and Import sit along the top.",
        ], picture: "WhatsNew-home"),
        Topic(id: "connect", symbol: "bolt.horizontal", title: "Connecting", steps: [
            "Quick Connect (⌘K): type user@host and press Return — SSH unless you type telnet://, sftp:// or ping.",
            "The ＋ in the tab bar opens a terminal, SSH, Serial, Telnet, Web or Ping tab.",
            "Right-click a tab: New Tab, Split with, Reconnect, Duplicate.",
            "Plug in a console cable: the card at the bottom right offers to connect.",
        ], picture: "Manual-newmenu"),
        Topic(id: "split", symbol: "rectangle.split.2x1", title: "Split panes", steps: [
            "Drag a host from the sidebar onto the edge of a pane — the side you drop on is where it opens.",
            "Drag a tab onto a pane's edge to join it; drag a pane's header onto the tab bar to give it its own tab.",
            "No drag needed: right-click a host ▸ Open in Split ▸ Right, Below, Left or Above, or a tab ▸ Split with.",
            "Tabs ▸ Split Right (⌘D) and Split Down (⇧⌘D) split the pane you are in; up to 3 × 3.",
        ], picture: nil),
        Topic(id: "addhost", symbol: "plus.rectangle.on.rectangle", title: "Adding a host", steps: [
            "Hosts ▸ Add Host… (⌘N), the ≡ at the bottom of the sidebar, or right-click a group.",
            "Pick the badge in front of the name: SSH, Server, Docker, Cloud or Jump.",
            "Authentication: Automatic, Password, Key or ssh-agent; a saved credential fills in the user.",
            "Consoles are not filed in groups — they stay in Recent.",
        ], picture: "WhatsNew-addhost"),
        Topic(id: "addhosts", symbol: "tablecells", title: "Adding many hosts", steps: [
            "Hosts ▸ Add Hosts… opens a table: type, name, host, credential, subgroup.",
            "Paste a block from a spreadsheet (⌘V) or Import… a CSV, JSON or OpenSSH config file; the Subgroup column files hosts under the group.",
            "Blank rows are skipped; Add Hosts saves the rest into the group picked at the top.",
        ], picture: "Manual-addhosts"),
        Topic(id: "rightclick", symbol: "contextualmenu.and.cursorarrow", title: "Right-click menus", steps: [
            "Empty sidebar space: Add Host, Add Hosts, New Group, Import.",
            "A group: Add Host Here, Add Subgroup, Group Icon, Set Credential for Group, Via Jump Server.",
            "A host: Connect, Open in Split, Open File, Ping, Edit Host.",
            "The ≡ at the bottom of the sidebar shows the same list in the same order.",
        ], picture: "WhatsNew-rightclick"),
        Topic(id: "groups", symbol: "folder", title: "Groups and icons", steps: [
            "New Group and Add Subgroup — up to four levels; drag hosts and groups to move them.",
            "Pick an icon and a colour when you make a group, or later: right-click ▸ Group Icon…",
            "The bar in front of the group follows its colour.",
        ], picture: "WhatsNew-groupicon"),
        Topic(id: "credentials", symbol: "key", title: "Credentials, keys and certificates", steps: [
            "Hosts ▸ Credentials… keeps users, passwords and SSH keys — in the Keychain, never in a file.",
            "Import a key from ~/.ssh or make a new one; add its certificate from your CA.",
            "Pick a credential on a host, or set one for a whole group.",
            "With Sync on, credentials travel end-to-end encrypted.",
        ], picture: "WhatsNew-credential-edit"),
        Topic(id: "jump", symbol: "arrow.triangle.branch", title: "Jump servers", steps: [
            "Give a host the Jump badge.",
            "In Reaches, pick the groups behind it — every host in them connects through it.",
            "Reaches ▸ New Host… adds a host behind it straight away.",
            "One hop only: a host that goes through a jump server cannot be one.",
        ], picture: "WhatsNew-jumphost"),
        Topic(id: "logs", symbol: "doc.text", title: "Session logs", steps: [
            "Settings ▸ Log Sessions to File; a host can opt out with Don't Log.",
            "File ▸ Logs… lists every log by day; a green dot = still being written.",
            "Double-click opens a log as a read-only tab; right-click for Finder, Copy Path or Trash.",
            "File ▸ Search Logs… (⇧⌘F) finds text inside every log.",
        ], picture: "Manual-logs"),
        Topic(id: "transfer", symbol: "arrow.up.arrow.down", title: "File transfer", steps: [
            "The glyph left of the clock opens the File Server: TFTP, SFTP, SCP or FTP on this Mac.",
            "Every server starts off, and stops by itself after 10 idle minutes.",
            "Open File… on an SSH host or tab browses it in a Files tab.",
        ], picture: nil),
        Topic(id: "optimize", symbol: "slider.horizontal.3", title: "Shape the app", steps: [
            "View ▸ Optimize… opens Settings ▸ Optimization.",
            "Pick Minimal, Standard or Dashboard, or switch things off one by one.",
            "Changed a preset? Save keeps it, Restore Default brings it back, ＋ saves a new one.",
            "A feature switched off only leaves the menus — nothing saved is touched.",
        ], picture: "WhatsNew-optimization"),
        Topic(id: "keys", symbol: "keyboard", title: "Keyboard shortcuts", steps: [
            "⌘K  Quick Connect",
            "⌘T  New Terminal Tab",
            "⇧⌘N  New SSH Tab",
            "⌘N  Add Host",
            "⇧⌘0  Home",
            "⌘0  Toggle Sidebar",
            "⌘F  Find",
            "⇧⌘F  Search Logs",
            "⌃⌥B  Send Break",
        ], picture: nil),
    ]

    /// The shortcut lines: "keys␣␣name" — the keys are not translated.
    static func shortcutParts(_ line: String) -> (keys: String, name: String)? {
        guard let gap = line.range(of: "  ") else { return nil }
        return (String(line[..<gap.lowerBound]), String(line[gap.upperBound...]))
    }

    /// Every string the guide shows, for the catalog check.
    static var strings: [String] {
        var out = ["SheepTerm Guide"]
        for topic in topics {
            out.append(topic.title)
            if topic.id == "keys" {
                out += topic.steps.compactMap { shortcutParts($0)?.name }
            } else {
                out += topic.steps
            }
        }
        return out
    }
}
