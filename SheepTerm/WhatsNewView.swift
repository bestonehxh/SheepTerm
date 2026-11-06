import SwiftUI

/// What's New for 6.1 (the user's design, mockup 10, at the sheet's old
/// 600 × 600): one change per page — a real picture of the app (sample data,
/// edges fading into the page, no frame), a few words and where to try it;
/// tips on the last page, and Start Optimize to shape the app. Opens on its own once
/// per release (`WhatsNewPlan`, recorded when SHOWN) and from Help ▸ What's
/// New…; Close / Esc any time.
struct WhatsNewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var page: Int

    init(page: Int = 0) { _page = State(initialValue: page) }

    private struct Feature: Identifiable {
        let id: Int
        let image: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let tryIt: LocalizedStringKey
    }

    private static let features: [Feature] = [
        Feature(id: 0, image: "WhatsNew-home", title: "Home",
                body: "Your recents, groups and hosts by type on one board — 1, 2 or 3 columns, add a host or a group right there.",
                tryIt: "Try it: the house at the start of the tab bar · ⇧⌘0"),
        Feature(id: 1, image: "WhatsNew-addhost", title: "Hosts that say what they are",
                body: "A badge in front of the name — SSH, Server, Docker, Cloud, Jump — and how it logs in: password, key, ssh-agent or automatic.",
                tryIt: "Try it: Hosts ▸ Add Host… ⌘N"),
        Feature(id: 2, image: "WhatsNew-rightclick", title: "Right-click to add",
                body: "Right-click empty space in the sidebar, a group or a host for Add Host, Add Hosts, New Group and Import, right where you are.",
                tryIt: "Try it: right-click below your groups"),
        Feature(id: 3, image: "WhatsNew-jumphost", title: "Jump servers",
                body: "Give a host the Jump badge, then pick the groups it Reaches — every host in them connects through it. Reaches ▸ New Host… adds one behind it.",
                tryIt: "Try it: the badge in front of a host's name ▸ Jump"),
        Feature(id: 4, image: "WhatsNew-groupicon", title: "Group icons",
                body: "Give a group an icon and a colour — the bar in front of it follows. Pick them when you make the group, or later.",
                tryIt: "Try it: right-click a group ▸ Group Icon…"),
        Feature(id: 5, image: "WhatsNew-credential-edit", title: "Keys and certificates",
                body: "Import a key from ~/.ssh or make a new one, add its certificate from your CA. It stays in the Keychain and syncs end-to-end encrypted.",
                tryIt: "Try it: Hosts ▸ Credentials…"),
        Feature(id: 6, image: "WhatsNew-optimization", title: "Shape the app around your work",
                body: "Minimal, Standard or Dashboard — edit any of them, save your own, or switch off what you never use.",
                tryIt: "Try it: View ▸ Optimize…"),
    ]

    static var featureCount: Int { features.count }

    private var lastPage: Int { Self.features.count }   // the features, then the tips page

    var body: some View {
        VStack(spacing: 0) {
            Text("What's new in SheepTerm 6.1")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dimText)
                .padding(.bottom, 10)
            if page < Self.features.count {
                featurePage(Self.features[page])
            } else {
                tips
            }
            Spacer(minLength: 0)

            // Close · dots · Back / Next, Start Optimize on the last page.
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0...lastPage, id: \.self) { i in
                        Circle().fill(i == page ? Theme.tabText : Theme.dimText.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                HStack(spacing: 8) {
                    Button("Close") { close() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if page > 0 {
                        Button("Back") { page -= 1 }
                    }
                    if page < lastPage {
                        Button("Next") { page += 1 }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        // Straight to the switches (the user, 6.0 (48)).
                        Button("Start Optimize") { close(); openOptimization() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 22)
        // The size it always had (the user, 6.0 (50)).
        .frame(width: 600, height: 600)
        .sheepSheetChrome()
        // Seen when SHOWN: a crash or force-quit never brings it back.
        .onAppear {
            let defaults = UserDefaults.standard
            defaults.set(WhatsNewPlan.seenAfterShowing(defaults.string(forKey: WhatsNewPlan.seenKey)), forKey: WhatsNewPlan.seenKey)
        }
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
        return Image(feature.image)
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

    private var tips: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Tips").font(.system(size: 22, weight: .semibold)).padding(.top, 8)
            tip("Logs in the app", "File ▸ Logs… lists every session log; double-click opens one as a read-only tab.")
            tip("Right-click anywhere", "Empty sidebar space, a group, a host or a tab — each has its add and open actions right there.")
            tip("Home or Search, your way", "Hide either, or move Home to the top bar: Settings ▸ Optimization ▸ Tab Bar.")
            tip("Shape the app", "Start Optimize: pick a preset, or switch off what you never use.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tip(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.dimText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close() { model.showWhatsNew = false }

    private func openOptimization() {
        SettingsView.openOnOptimization = true
        openSettings()
        NotificationCenter.default.post(name: SettingsView.showOptimization, object: nil)
    }
}
