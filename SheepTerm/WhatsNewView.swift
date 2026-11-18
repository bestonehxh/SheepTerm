import SwiftUI

/// What's New for 6.1 (the user's design, mockup 10, at the sheet's old
/// 600 × 600): one change per page — a real picture of the app (sample data,
/// edges fading into the page, no frame), a few words and where to try it;
/// tips on the last page, and Start Optimize to shape the app. Opens on its
/// own after an update with only what that update brought (`WhatsNewPlan`,
/// 6.1 (64)) and from Help ▸ What's New… with everything; Close / Esc any time.
struct WhatsNewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var page: Int
    /// What this window shows (`WhatsNewPlan.selection`): everything from
    /// Help, only what this upgrade brought on launch.
    private let selection: WhatsNewPlan.Selection

    init(selection: WhatsNewPlan.Selection = WhatsNewPlan.everything, page: Int = 0) {
        self.selection = selection
        _page = State(initialValue: WhatsNewPlan.debugPage(page, count: selection.pageCount))
    }

    private struct Feature {
        let id: String
        /// nil = a page of words: one symbol per line (`lines`).
        let image: String?
        let title: LocalizedStringKey
        var body: LocalizedStringKey = ""
        var tryIt: LocalizedStringKey = ""
        var lines: [(symbol: String, text: LocalizedStringKey)] = []
    }

    /// Keyed by `WhatsNewPlan.pages`' ids, which carry the order and the
    /// release each arrived in.
    private static let features: [Feature] = [
        // 6.2 (1): what 6.1 (58)–(64) brought (the first public build after 6.1 (57)).
        Feature(id: "banner", image: "WhatsNew-login-banner", title: "Login banners",
                body: "A device's login banner now prints in the terminal, as OpenSSH shows it.",
                tryIt: "Try it: connect to a device over SSH"),
        Feature(id: "steadier", image: nil, title: "Faster and steadier",
                lines: [("point.3.connected.trianglepath.dotted", "Connecting through a jump server no longer stalls."),
                        ("hare", "Home, search and the Logs window stay quick, even with many groups."),
                        ("moon.zzz", "Idle tabs no longer wake your Mac every second."),
                        ("arrow.triangle.2.circlepath", "Sync keeps your newest change when two Macs edit the same setting.")]),
        Feature(id: "home", image: "WhatsNew-home", title: "Home",
                body: "Your recents, groups and hosts by type on one board — 1, 2 or 3 columns, add a host or a group right there.",
                tryIt: "Try it: the house at the start of the tab bar · ⇧⌘0"),
        Feature(id: "workspaces", image: "WhatsNew-workspaces", title: "Workspaces",
                body: "Split your hosts into sets of work — a customer, the lab, General for the rest — and switch with the chip at the head of the sidebar's search field.",
                tryIt: "Try it: right-click a group ▸ Move to Workspace"),
        Feature(id: "badges", image: "WhatsNew-addhost", title: "Hosts that say what they are",
                body: "A badge in front of the name — SSH, Server, Docker, Cloud, Jump — and how it logs in: password, key, ssh-agent or automatic.",
                tryIt: "Try it: Hosts ▸ Add Host… ⌘N"),
        Feature(id: "rightclick", image: "WhatsNew-rightclick", title: "Right-click to add",
                body: "Right-click empty space in the sidebar, a group or a host for Add Host, Add Hosts, New Group and Import, right where you are.",
                tryIt: "Try it: right-click below your groups"),
        Feature(id: "import", image: "WhatsNew-import", title: "Import from other apps",
                body: "Add Hosts reads the sessions PuTTY, SecureCRT and MobaXterm export, and hosts files — every row to look over before Add. Passwords are never read.",
                tryIt: "Try it: Hosts ▸ Add Hosts… ▸ Import…"),
        Feature(id: "jump", image: "WhatsNew-jumphost", title: "Jump servers",
                body: "Make a host a Jump server and pick the groups it Reaches — every host in them connects through it. A route can pass up to four, one behind another.",
                tryIt: "Try it: Hosts ▸ Add Host… ▸ Jump"),
        Feature(id: "groupicon", image: "WhatsNew-groupicon", title: "Group icons",
                body: "Give a group an icon and a colour — the bar in front of it follows. Pick them when you make the group, or later.",
                tryIt: "Try it: right-click a group ▸ Group Icon…"),
        Feature(id: "trash", image: "WhatsNew-recently-deleted", title: "Recently Deleted",
                body: "A host or a group you delete is kept for 30 days, everything in it, and can be put back where it was.",
                tryIt: "Try it: the sidebar's ≡ ▸ Recently Deleted…, once something is deleted"),
        Feature(id: "savesplit", image: "WhatsNew-save-split", title: "Save Split",
                body: "Keep a tab of several panes as one row in the sidebar. Open it and the same panes come back, laid out as saved, each connecting.",
                tryIt: "Try it: right-click a split tab ▸ Save Split…"),
        Feature(id: "keys", image: "WhatsNew-credential-edit", title: "Keys and certificates",
                body: "Import a key from ~/.ssh or make a new one, add its certificate from your CA. It stays in the Keychain and syncs end-to-end encrypted.",
                tryIt: "Try it: Hosts ▸ Credentials…"),
        Feature(id: "optimize", image: "WhatsNew-optimization", title: "Shape the app around your work",
                body: "Minimal, Standard or Dashboard — edit any of them, save your own, or switch off what you never use.",
                tryIt: "Try it: View ▸ Optimize…"),
    ]

    private struct Tip {
        let id: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    /// Keyed by `WhatsNewPlan.tips`' ids (their order = the reading order).
    private static let tipList: [Tip] = [
        Tip(id: "logs", title: "Logs in the app", text: "File ▸ Logs… lists every session log; double-click opens one as a read-only tab."),
        Tip(id: "rightclickall", title: "Right-click anywhere", text: "Empty sidebar space, a group, a host or a tab — each has its add and open actions right there."),
        Tip(id: "homesearch", title: "Home or Search, your way", text: "Hide either, or move Home to the top bar: Settings ▸ Optimization ▸ Tab Bar."),
        Tip(id: "reopen", title: "Reopen Last Tabs", text: "Settings ▸ Optimization ▸ Tab Bar: the tabs open at quit come back. Off unless turned on."),
        Tip(id: "depth", title: "Groups seven levels deep", text: "Right-click a group ▸ Add Subgroup…, down to seven levels."),
        Tip(id: "zmodem", title: "ZMODEM", text: "Type sz or rz on the far end of an SSH or console tab to receive or send a file."),
        Tip(id: "broadcast", title: "Broadcast several commands", text: "Snippets ▸ Broadcast to Tabs… sends every line, one at a time, to each ticked tab."),
        Tip(id: "topbar", title: "Right-click the top bar", text: "It is the ＋ menu, right at the pointer."),
        Tip(id: "stopwatch", title: "Stopwatch and Rack Fill", text: "Tabs ▸ Stopwatch (⌥⌘T) times a reload; Tabs ▸ Rack Fill is a puzzle for the wait."),
        Tip(id: "optimize", title: "Shape the app", text: "Start Optimize: pick a preset, or switch off what you never use."),
    ]

    static var featureCount: Int { features.count }
    static var featureIDs: [String] { features.map(\.id) }
    static var tipIDs: [String] { tipList.map(\.id) }

    private var shownFeatures: [Feature] { selection.pages.compactMap { id in Self.features.first { $0.id == id } } }
    private var shownTips: [Tip] { selection.tips.compactMap { id in Self.tipList.first { $0.id == id } } }
    private var lastPage: Int { max(selection.pageCount - 1, 0) }   // the features, then the tips page

    var body: some View {
        let features = shownFeatures
        VStack(spacing: 0) {
            Text("What's new in SheepTerm 6.2")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dimText)
                .padding(.bottom, 10)
            if page < features.count {
                if features[page].image == nil { wordsPage(features[page]) } else { featurePage(features[page]) }
            } else {
                tips
            }
            Spacer(minLength: 0)

            // Close · dots · Back / Next, Done (or Start Optimize after the
            // tips) on the last page. The dots sit in the room between the
            // buttons (6.1 (60)): twelve of them centred on the sheet ran into
            // a long Back / Start Optimize (French, Russian…). One page: no
            // dots, a single Done (Esc too).
            HStack(spacing: 8) {
                if selection.pageCount > 1 {
                    Button("Close") { close() }
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        ForEach(0...lastPage, id: \.self) { i in
                            Circle().fill(i == page ? Theme.tabText : Theme.dimText.opacity(0.4)).frame(width: 6, height: 6)
                        }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 12)
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                if page < lastPage {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else if selection.endsWithOptimize {
                    // Straight to the switches (the user, 6.0 (48)).
                    Button("Start Optimize") { close(); openOptimization() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 22)
        // The size it always had (the user, 6.0 (50)).
        .frame(width: 600, height: 600)
        .sheepSheetChrome()
        // Esc closes a one-page window too (it has no Close button).
        .onExitCommand { close() }
        // Seen when SHOWN: a crash or force-quit never brings it back.
        .onAppear {
            let defaults = UserDefaults.standard
            defaults.set(WhatsNewPlan.seenAfterShowing(defaults.string(forKey: WhatsNewPlan.seenKey)), forKey: WhatsNewPlan.seenKey)
        }
    }

    /// A page with no picture (6.1 (64)): the title where the Tips page has
    /// its own, then a symbol per line — the 6.0 (14) pages' style.
    private func wordsPage(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(feature.title).font(.system(size: 22, weight: .semibold)).padding(.top, 8)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(feature.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: line.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.12)))
                        Text(line.text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featurePage(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            picture(feature)
            Text(feature.title).font(.system(size: 22, weight: .semibold)).padding(.top, 18)
            Text(feature.body).font(.system(size: 13)).foregroundStyle(Theme.dimText)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Text(feature.tryIt).font(.system(size: 12)).foregroundStyle(Theme.accent).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The real UI in its window's edge (the user, 6.0 (50): a sheet shown
    /// with its border reads as the window it is, not loose fields).
    private func picture(_ feature: Feature) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Image(feature.image ?? "")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.chromeLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .frame(maxWidth: 536, maxHeight: 290)
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .accessibilityHidden(true)
    }

    /// The tips at the page's type sizes (6.1 (60)): one column ran past
    /// the 600 × 600 sheet, so two, read row by row — no scroll, no smaller
    /// type. Paired in `WhatsNewPlan.tips`' order (the rows are as tall as
    /// their longer tip).
    private var tips: some View {
        let shown = shownTips
        return VStack(alignment: .leading, spacing: 10) {
            Text("Tips").font(.system(size: 22, weight: .semibold)).padding(.top, 8)
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { i in
                    GridRow {
                        tip(shown[i])
                        if i + 1 < shown.count { tip(shown[i + 1]) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tip(_ tip: Tip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tip.title).font(.system(size: 14, weight: .semibold))
            Text(tip.text).font(.system(size: 13)).foregroundStyle(Theme.dimText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func close() { model.showWhatsNew = false }

    private func openOptimization() {
        SettingsView.openOnOptimization = true
        openSettings()
        NotificationCenter.default.post(name: SettingsView.showOptimization, object: nil)
    }
}
