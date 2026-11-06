import Foundation

/// Settings ▸ Optimization (6.1): every switch that shapes the app, and the
/// role presets that set them all at once. Pure — the harness checks it
/// (`Tests/tests/OptimizationTests.swift`); the view only reads and writes it.
///
/// The role shown is never stored: it is whichever preset equals the current
/// values, else Custom — so touching any switch makes it Custom by itself,
/// and a hand-made setup that happens to equal a preset shows that preset.
nonisolated enum OptimizationPlan {
    enum Role: String, CaseIterable, Identifiable {
        case network, sysadmin, devops, custom
        var id: String { rawValue }
    }

    /// Where the ＋ sits in the tab bar. Far right is the app as it was.
    enum NewTabButton: String, CaseIterable, Identifiable, Codable {
        case farRight, afterLastTab
        var id: String { rawValue }
    }

    /// Which tab a launch opens on.
    enum LaunchTab: String, CaseIterable, Identifiable, Codable {
        case terminal, home
        var id: String { rawValue }
    }

    /// Settings ▸ Optimization ▸ Features (6.0 (29)). Turning one off only
    /// HIDES it — from menus, forms and the bottom bar; a saved host of that
    /// kind still opens, nothing stored is touched. On = the app as it ships,
    /// except the four new ones (Key-based SSH first, Port forwards in Add
    /// Host, Environment tags, Cloud & Docker), which start off.
    enum Feature: String, CaseIterable, Identifiable, Sendable {
        case keyFirst, jumpServers, forwardsInAddHost, telnet, serial
        case environmentTags, cloudDocker, deviceFamilies, broadcast

        var id: String { rawValue }
        var key: String { "feature." + rawValue }
        var defaultOn: Bool {
            switch self {
            // Cloud & Docker shows from the start (the user, 6.0 (32): "where
            // did Docker and Cloud go?") — a type in a menu sends nothing.
            case .keyFirst, .forwardsInAddHost, .environmentTags: return false
            default: return true
            }
        }

        static func isOn(_ feature: Feature, in defaults: UserDefaults = .standard) -> Bool {
            defaults.object(forKey: feature.key) as? Bool ?? feature.defaultOn
        }

        static var defaults: [Feature: Bool] {
            Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultOn) })
        }
    }

    /// Where the Home button sits (6.0 (40)): the strip's first chip, or an
    /// icon in the top bar beside Sidebar.
    enum HomePlace: String, CaseIterable, Identifiable, Codable {
        case tabStrip, topBar
        var id: String { rawValue }
    }

    static let newTabButtonKey = "newTabButtonPosition"
    static let showHomeButtonKey = "showHomeButton"
    static let showSearchButtonKey = "showSearchButton"
    static let homePlaceKey = "homeButtonPlace"
    static let launchTabKey = "launchTab"

    // MARK: Home first (6.1 (4), the owner: "ติดตั้งใหม่ให้หน้า Home เป็นหน้าแรก
    // และคนที่อัพเดทก็ให้ถามด้วย ... ปิดกลับได้ที่ Optimize")

    /// What this build pinned on an updater to what it had (key → value):
    /// the launch tab (a terminal) and the three bottom-bar items that
    /// started hidden before 6.1 (3) — those writes are not the user's own.
    static let pinnedKey = "optimizationPinned"
    /// Before 6.1 (3)/(4) a Mac that never chose had these; `Settings()` now ships otherwise.
    static let shippedBefore: [String: String] = [
        launchTabKey: LaunchTab.terminal.rawValue,
        "statusShowSession": "false", "statusShowHints": "false", "statusShowIP": "false",
    ]
    /// The one question to an updater: Home first? nil = not asked yet.
    static let homeFirstAskedKey = "homeFirstAsked"

    /// The launch tab: the one chosen, else what the app ships (`Settings()`: Home).
    static func launchTab(_ d: UserDefaults) -> LaunchTab {
        d.string(forKey: launchTabKey).flatMap(LaunchTab.init(rawValue:)) ?? Settings().launchTab
    }

    /// At launch, before anything reads these: a Mac that used an earlier
    /// build keeps what it had where it never chose — a terminal first (and
    /// it is asked once, `needsHomeFirstAsk`), Session / Hints / IP hidden
    /// (Fable round 18: they appeared by themselves on an updater); a new
    /// Mac gets what ships (`Settings()`: Home, shown). Once per Mac.
    /// Returns whether the launch tab was pinned.
    @discardableResult
    static func pinLaunchTabIfUpdating(_ d: UserDefaults, usedBefore: Bool) -> Bool {
        // Once: the record of what was pinned says it is done.
        guard d.object(forKey: pinnedKey) == nil else { return false }
        guard usedBefore else {
            d.set([String: String](), forKey: pinnedKey)
            d.set(true, forKey: homeFirstAskedKey)   // a new Mac: what ships, nothing to ask
            return false
        }
        var pinned: [String: String] = [:]
        for (key, value) in shippedBefore where d.object(forKey: key) == nil {
            if key == launchTabKey { d.set(value, forKey: key) } else { d.set(value == "true", forKey: key) }
            pinned[key] = value
        }
        d.set(pinned, forKey: pinnedKey)
        // A launch tab chosen by hand before is the answer already (Fable round 19:
        // chosen Home, later Terminal by hand, was then asked "Start on Home?").
        if pinned[launchTabKey] == nil { d.set(true, forKey: homeFirstAskedKey) }
        return pinned[launchTabKey] != nil
    }

    /// Ask the updater (once) whether Home goes first — only while its launch
    /// tab is still the one this build pinned.
    static func needsHomeFirstAsk(_ d: UserDefaults) -> Bool {
        d.object(forKey: homeFirstAskedKey) == nil && isPinned(launchTabKey, d)
    }

    /// The answer: Home first, or keep the terminal; never asked again.
    /// Either way the launch tab is the USER's now — no longer pinned, so it
    /// counts, syncs and matches as it is (Fable round 20: Not Now stayed pinned).
    /// Either answer is WRITTEN — Not Now too (Fable round 21: Sync could
    /// bring another Mac's Home while the question was up, and Not Now then
    /// left it).
    static func answerHomeFirst(_ d: UserDefaults, home: Bool) {
        d.set(true, forKey: homeFirstAskedKey)
        d.set((home ? LaunchTab.home : .terminal).rawValue, forKey: launchTabKey)
        unpinLaunchTab(d)
    }

    /// The launch tab is the user's now (an answer, a preset picked): no
    /// longer pinned, even when the value is the same.
    static func unpinLaunchTab(_ d: UserDefaults) {
        guard var pinned = d.dictionary(forKey: pinnedKey) as? [String: String], pinned[launchTabKey] != nil else { return }
        pinned[launchTabKey] = nil
        d.set(pinned, forKey: pinnedKey)
    }

    /// A pinned value that has changed — by hand, a preset or Sync — is the
    /// user's from then on, for good, even if it later goes back to the same
    /// value (6.1 (12), the Windows port's Fable review: Session on then off
    /// again read as pinned, so the "off" never synced). `AppModel` runs this
    /// on every defaults change, before Sync's debounced read.
    static func settlePins(_ d: UserDefaults) {
        guard let pinned = d.dictionary(forKey: pinnedKey) as? [String: String], !pinned.isEmpty else { return }
        let kept = pinned.filter { key, _ in d.object(forKey: key) == nil || isPinned(key, d) }
        if kept.count != pinned.count { d.set(kept, forKey: pinnedKey) }
    }

    /// A value this build pinned for an updater and nobody has changed since.
    /// Not the user's: it never counts as touched, never goes to Sync (Fable
    /// round 19: it beat another Mac's own answer there), and never makes a
    /// setup Custom.
    static func isPinned(_ key: String, _ d: UserDefaults) -> Bool {
        guard let was = (d.dictionary(forKey: pinnedKey) as? [String: String])?[key], let value = d.object(forKey: key) else { return false }
        if was == "true" || was == "false" { return (value as? Bool) == (was == "true") }
        return (value as? String) == was
    }

    /// Keys that say the user changed a switch — a pinned value is not one.
    static func touched(_ d: UserDefaults) -> Bool {
        storedKeys.contains { d.object(forKey: $0) != nil && !isPinned($0, d) }
    }

    /// The setup as presets are matched against it: a pinned launch tab reads
    /// as what ships, so an updater on Minimal stays Minimal until it answers
    /// "Start on Home?" (Fable round 19).
    static func forMatching(_ s: Settings, _ d: UserDefaults) -> Settings {
        guard isPinned(launchTabKey, d) else { return s }
        var out = s
        out.launchTab = Settings().launchTab
        return out
    }

    struct Settings: Equatable {
        // Sidebar
        var sidebarAtLaunch = false
        var sidebarStaysOpen = false
        var groupColors = true
        /// Host badges coloured by type (6.0 (28)) — false = all grey.
        var colouredBadges = true
        var showRecents = true
        var recentsShown = 5
        // Bottom Bar
        var showStatusBar = true
        var connectionStatus = "wool"
        var statusShowSession = true
        var statusShowHints = true
        var statusShowIP = true
        var statusShowClock = true
        var statusShowFileServer = true
        var statusShowTransfers = true
        // Tab bar
        /// After the last tab by default (the user, 6.0 (32)).
        var newTabButton = NewTabButton.afterLastTab
        /// Home / Search buttons (6.0 (40)): either can go; Home can move.
        var showHomeButton = true
        var showSearchButton = true
        var homePlace = HomePlace.tabStrip
        /// Home first (6.1 (4)): a new Mac, and every preset built on this.
        var launchTab = LaunchTab.home
        // Connect / Work
        var autoReconnect = true
        var autoPage = false
        var dangerGuard = true
        var safePaste = true
        var logSessions = true
        // AI
        var aiEnabled = true
        var aiPanelShown = false
        // Features
        var features: [Feature: Bool] = Feature.defaults
    }

    /// Shown as Minimal · Standard · Dashboard (6.0 (50); the cases keep their
    /// first names). Minimal (`network`) is the user's own setup (6.1 (2)) —
    /// the app as it ships plus three switches off. Auto-page stays OFF in
    /// every preset: it sends keys to the device, and that is only ever the
    /// user's own switch.
    static func preset(_ role: Role) -> Settings? {
        var s = Settings()
        switch role {
        case .network:
            // Minimal = the setup the user runs (6.1 (2), read off their
            // Mac): no connection dot, no file-server glyph, no command guard;
            // ＋ after the last tab like every preset.
            s.connectionStatus = "off"
            s.statusShowFileServer = false
            s.dangerGuard = false
            return s
        case .sysadmin:
            s.connectionStatus = "off"
            s.statusShowHints = false
            s.statusShowFileServer = false
            s.dangerGuard = false
            s.features[.keyFirst] = true
            s.features[.telnet] = false
            s.features[.serial] = false
            s.features[.environmentTags] = true
            s.features[.cloudDocker] = false
            s.features[.deviceFamilies] = false
            return s
        case .devops:
            s.connectionStatus = "off"
            s.statusShowHints = false
            s.statusShowFileServer = false
            s.dangerGuard = false
            s.launchTab = .home
            s.aiPanelShown = true
            s.features[.keyFirst] = true
            s.features[.forwardsInAddHost] = true
            s.features[.telnet] = false
            s.features[.serial] = false
            s.features[.environmentTags] = true
            s.features[.deviceFamilies] = false
            return s
        case .custom:
            return nil
        }
    }

    /// The role whose preset equals `current`; Custom when none does.
    /// The recent-entry count and Auto-page are the user's own, so they never
    /// make a setup Custom.
    static func role(of current: Settings, edited: [Role: Settings] = [:]) -> Role {
        Role.allCases.first { role in
            guard let preset = edited[role] ?? preset(role) else { return false }
            return matches(current, preset)
        } ?? .custom
    }

    /// Minimal / Standard / Dashboard as the user saved them (6.0 (52), the
    /// user: "edit Minimal, with Save and Restore Default"); a role absent
    /// here is the shipped one (`preset(_:)`).
    static let builtInsKey = "optimizationBuiltIns"

    static func loadBuiltIns(_ data: Data?) -> [Role: Settings] {
        guard let data, let raw = try? JSONDecoder().decode([String: Settings].self, from: data) else { return [:] }
        var out: [Role: Settings] = [:]
        for (key, value) in raw { if let role = Role(rawValue: key), role != .custom { out[role] = value } }
        return out
    }

    static func encodeBuiltIns(_ edited: [Role: Settings]) -> Data? {
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: edited.map { ($0.key.rawValue, $0.value) }))
    }

    /// Every key a `Settings` field is stored under: a Mac where none is set
    /// never touched a switch (a fresh install), so there is nothing to keep.
    static let storedKeys: [String] = [
        "sidebarAtLaunch", "sidebarStaysOpen", "sidebarGroupColors", "hostBadgeStyle", "showRecents", "recentsShown",
        "showStatusBar", "statusConnectionStyle", "statusShowSession", "statusShowHints", "statusShowIP", "statusShowClock",
        "statusShowFileServer", "statusShowTransfers", newTabButtonKey, showHomeButtonKey, showSearchButtonKey, homePlaceKey,
        launchTabKey, "autoReconnect", "confirmDangerousCommands", "safePasteEnabled", "logSessions", "aiEnabled", "aiPanelShown",
    ] + Feature.allCases.map(\.key)

    /// The name the setup from before 6.1 is kept under (localised by the caller).
    static let beforeUpdateKey = "optimizationKeptBeforeUpdate"

    /// 6.1 (2), the user: whoever updates keeps what they had set — once,
    /// as a saved preset (first in the row) that is also the one shown.
    /// Nothing for a fresh install, a setup that IS a built-in, one already
    /// saved, or a full list. Returns the new list, or nil = leave it.
    /// The setup as it stood when this build first launched, KEPT on disk
    /// until decided (Fable round 15: held in memory only, a launch that
    /// quit before Sync's first pull lost it — the next launch read the
    /// preset picked meanwhile).
    struct SetupBeforeUpdate: Codable, Equatable {
        let settings: Settings
        let touched: Bool
        /// The launch tab was this build's pin when READ (Fable round 20: judged
        /// when read, not when decided — an answer or a pull between the two
        /// must not change the outcome).
        var launchPinned = false

        init(settings: Settings, touched: Bool, launchPinned: Bool = false) {
            self.settings = settings; self.touched = touched; self.launchPinned = launchPinned
        }

        /// A copy kept by an earlier 6.1 build has no `launchPinned`: read as
        /// false, not refused (Fable round 21: the synthesized decoder threw,
        /// and the kept setup was read again NOW).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = try c.decode(Settings.self, forKey: .settings)
            touched = try c.decode(Bool.self, forKey: .touched)
            launchPinned = try c.decodeIfPresent(Bool.self, forKey: .launchPinned) ?? false
        }

        /// What presets are matched against: a pinned launch tab as what ships.
        var forMatching: Settings {
            guard launchPinned else { return settings }
            var s = settings
            s.launchTab = Settings().launchTab
            return s
        }
    }

    static let setupBeforeUpdateKey = "optimizationSetupBeforeUpdate"

    /// The setup to decide on: the one already kept, else `current()` read
    /// now and kept; nil once this Mac has decided.
    static func setupBeforeUpdate(_ d: UserDefaults, current: () -> Settings) -> SetupBeforeUpdate? {
        guard d.object(forKey: beforeUpdateKey) == nil else { return nil }
        if let data = d.data(forKey: setupBeforeUpdateKey), let kept = try? JSONDecoder().decode(SetupBeforeUpdate.self, from: data) {
            return kept
        }
        let setup = SetupBeforeUpdate(settings: current(), touched: touched(d), launchPinned: isPinned(launchTabKey, d))
        d.set(try? JSONEncoder().encode(setup), forKey: setupBeforeUpdateKey)
        return setup
    }

    /// Decided: never again on this Mac, and the kept copy goes.
    static func markDecided(_ d: UserDefaults) {
        d.set(true, forKey: beforeUpdateKey)
        d.removeObject(forKey: setupBeforeUpdateKey)
    }

    /// The kept setup is shown as the current choice only while the
    /// switches still are that setup (Fable round 14: a preset picked while
    /// Sync's first pull ran must not be relabelled).
    static func showsKept(_ kept: Settings, now: Settings) -> Bool { matches(now, kept) }

    /// `matchingAs`: what the presets are compared with (a pinned launch tab
    /// read as what ships); the kept preset holds `current` as it really is
    /// (Fable round 20: it carried Home and switched an updater to it).
    static func keepingBeforeUpdate(_ current: Settings, matchingAs: Settings? = nil, touched: Bool, saved: [SavedPreset], name: String,
                                    edited: [Role: Settings] = [:]) -> [SavedPreset]? {
        let probe = matchingAs ?? current
        guard touched, role(of: probe, edited: edited) == .custom, saved.count < savedLimit,
              !saved.contains(where: { matches(probe, $0.settings) || matches(current, $0.settings) }) else { return nil }
        return [SavedPreset(name: uniqueName(name, among: saved) ?? name, settings: current)] + saved
    }

    /// The user's own sets (6.0 (51), the user: "save a preset while on
    /// Custom, to switch between"). Kept in UserDefaults, in Backup and Sync.
    struct SavedPreset: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var settings: Settings
    }

    static let savedPresetsKey = "optimizationPresets"
    /// The segmented row holds the three built-ins, these and Custom.
    static let savedLimit = 4

    static func loadSaved(_ data: Data?) -> [SavedPreset] {
        guard let data, let list = try? JSONDecoder().decode([SavedPreset].self, from: data) else { return [] }
        return Array(list.prefix(savedLimit))
    }

    static func encodeSaved(_ list: [SavedPreset]) -> Data? { try? JSONEncoder().encode(list) }

    /// Same rule as the built-ins: the recent-entry count and Auto-page never
    /// make two setups differ.
    /// One rule for every preset, shipped, edited or saved (Fable round 8):
    /// what `keepingLocal` keeps never makes two setups differ.
    static func matches(_ current: Settings, _ preset: Settings) -> Bool {
        keepingLocal(preset, from: current) == current
    }

    /// No preset touches this Mac's window (Fable rounds 6–8): Sync keeps
    /// Sidebar at Launch / Keep Open / Group Colors per Mac, so no preset —
    /// shipped, edited or saved — flips them or fails to match on them; nor
    /// the recent count or Auto-page, the user's own.
    static func keepingLocal(_ settings: Settings, from current: Settings) -> Settings {
        var out = settings
        out.recentsShown = current.recentsShown
        out.autoPage = current.autoPage
        out.sidebarAtLaunch = current.sidebarAtLaunch
        out.sidebarStaysOpen = current.sidebarStaysOpen
        out.groupColors = current.groupColors
        return out
    }

    /// The saved set the switches match — only when no built-in does.
    static func savedMatch(_ current: Settings, in saved: [SavedPreset], edited: [Role: Settings] = [:]) -> SavedPreset? {
        guard role(of: current, edited: edited) == .custom else { return nil }
        return saved.first { matches(current, $0.settings) }
    }

    /// Whether the row stays segmented: the built-ins' labels take ~29
    /// characters; past ~52 in all the pane (700 pt) runs out.
    static func fitsSegments(_ savedNames: [String]) -> Bool {
        savedNames.reduce(0) { $0 + $1.count } <= 22
    }

    /// A name a segment can hold (Fable round 6: long names pushed ＋/⋯ out).
    static let nameLimit = 20

    /// A trimmed, non-empty, short name no other set has — saved or built-in
    /// (`builtIn` = the labels the picker shows) — "Lab", "Lab 2" …
    static func uniqueName(_ typed: String, among saved: [SavedPreset], except id: UUID? = nil,
                           builtIn: [String] = []) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String(trimmed.prefix(nameLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let taken = Set(saved.filter { $0.id != id }.map { $0.name.lowercased() } + builtIn.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        // The number fits inside the limit too (Fable round 7).
        var n = 2
        func numbered(_ n: Int) -> String {
            let suffix = " \(n)"
            return String(base.prefix(nameLimit - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
        }
        while taken.contains(numbered(n).lowercased()) { n += 1 }
        return numbered(n)
    }

    /// Applying a saved set keeps what no preset decides, as `applying` does.
    static func applying(_ saved: SavedPreset, to current: Settings) -> Settings {
        keepingLocal(saved.settings, from: current)
    }

    /// Applying a preset keeps the parts no preset decides: how many recent
    /// entries (a number the user typed) — and Auto-page, the user's alone.
    static func applying(_ role: Role, to current: Settings, edited: [Role: Settings] = [:]) -> Settings {
        guard role != .custom, let preset = edited[role] ?? preset(role) else { return current }
        return keepingLocal(preset, from: current)
    }
}


nonisolated extension OptimizationPlan.Settings: Codable {
    // A saved preset (6.0 (51)) is read field by field: one written before
    // a switch existed keeps that switch's default instead of failing.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sidebarAtLaunch, sidebarStaysOpen, groupColors, colouredBadges, showRecents, recentsShown, showStatusBar, connectionStatus, statusShowSession, statusShowHints, statusShowIP, statusShowClock, statusShowFileServer, statusShowTransfers, newTabButton, showHomeButton, showSearchButton, homePlace, launchTab, autoReconnect, autoPage, dangerGuard, safePaste, logSessions, aiEnabled, aiPanelShown, features
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        self = base
        sidebarAtLaunch = (try? c.decodeIfPresent(type(of: base.sidebarAtLaunch), forKey: .sidebarAtLaunch)) ?? base.sidebarAtLaunch
        sidebarStaysOpen = (try? c.decodeIfPresent(type(of: base.sidebarStaysOpen), forKey: .sidebarStaysOpen)) ?? base.sidebarStaysOpen
        groupColors = (try? c.decodeIfPresent(type(of: base.groupColors), forKey: .groupColors)) ?? base.groupColors
        colouredBadges = (try? c.decodeIfPresent(type(of: base.colouredBadges), forKey: .colouredBadges)) ?? base.colouredBadges
        showRecents = (try? c.decodeIfPresent(type(of: base.showRecents), forKey: .showRecents)) ?? base.showRecents
        recentsShown = (try? c.decodeIfPresent(type(of: base.recentsShown), forKey: .recentsShown)) ?? base.recentsShown
        showStatusBar = (try? c.decodeIfPresent(type(of: base.showStatusBar), forKey: .showStatusBar)) ?? base.showStatusBar
        connectionStatus = (try? c.decodeIfPresent(type(of: base.connectionStatus), forKey: .connectionStatus)) ?? base.connectionStatus
        statusShowSession = (try? c.decodeIfPresent(type(of: base.statusShowSession), forKey: .statusShowSession)) ?? base.statusShowSession
        statusShowHints = (try? c.decodeIfPresent(type(of: base.statusShowHints), forKey: .statusShowHints)) ?? base.statusShowHints
        statusShowIP = (try? c.decodeIfPresent(type(of: base.statusShowIP), forKey: .statusShowIP)) ?? base.statusShowIP
        statusShowClock = (try? c.decodeIfPresent(type(of: base.statusShowClock), forKey: .statusShowClock)) ?? base.statusShowClock
        statusShowFileServer = (try? c.decodeIfPresent(type(of: base.statusShowFileServer), forKey: .statusShowFileServer)) ?? base.statusShowFileServer
        statusShowTransfers = (try? c.decodeIfPresent(type(of: base.statusShowTransfers), forKey: .statusShowTransfers)) ?? base.statusShowTransfers
        newTabButton = (try? c.decodeIfPresent(type(of: base.newTabButton), forKey: .newTabButton)) ?? base.newTabButton
        showHomeButton = (try? c.decodeIfPresent(type(of: base.showHomeButton), forKey: .showHomeButton)) ?? base.showHomeButton
        showSearchButton = (try? c.decodeIfPresent(type(of: base.showSearchButton), forKey: .showSearchButton)) ?? base.showSearchButton
        homePlace = (try? c.decodeIfPresent(type(of: base.homePlace), forKey: .homePlace)) ?? base.homePlace
        launchTab = (try? c.decodeIfPresent(type(of: base.launchTab), forKey: .launchTab)) ?? base.launchTab
        autoReconnect = (try? c.decodeIfPresent(type(of: base.autoReconnect), forKey: .autoReconnect)) ?? base.autoReconnect
        autoPage = (try? c.decodeIfPresent(type(of: base.autoPage), forKey: .autoPage)) ?? base.autoPage
        dangerGuard = (try? c.decodeIfPresent(type(of: base.dangerGuard), forKey: .dangerGuard)) ?? base.dangerGuard
        safePaste = (try? c.decodeIfPresent(type(of: base.safePaste), forKey: .safePaste)) ?? base.safePaste
        logSessions = (try? c.decodeIfPresent(type(of: base.logSessions), forKey: .logSessions)) ?? base.logSessions
        aiEnabled = (try? c.decodeIfPresent(type(of: base.aiEnabled), forKey: .aiEnabled)) ?? base.aiEnabled
        aiPanelShown = (try? c.decodeIfPresent(type(of: base.aiPanelShown), forKey: .aiPanelShown)) ?? base.aiPanelShown
        let saved = (try? c.decodeIfPresent([String: Bool].self, forKey: .features)) ?? nil
        features = Dictionary(uniqueKeysWithValues: OptimizationPlan.Feature.allCases.map { ($0, saved?[$0.rawValue] ?? base.features[$0] ?? $0.defaultOn) })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sidebarAtLaunch, forKey: .sidebarAtLaunch)
        try c.encode(sidebarStaysOpen, forKey: .sidebarStaysOpen)
        try c.encode(groupColors, forKey: .groupColors)
        try c.encode(colouredBadges, forKey: .colouredBadges)
        try c.encode(showRecents, forKey: .showRecents)
        try c.encode(recentsShown, forKey: .recentsShown)
        try c.encode(showStatusBar, forKey: .showStatusBar)
        try c.encode(connectionStatus, forKey: .connectionStatus)
        try c.encode(statusShowSession, forKey: .statusShowSession)
        try c.encode(statusShowHints, forKey: .statusShowHints)
        try c.encode(statusShowIP, forKey: .statusShowIP)
        try c.encode(statusShowClock, forKey: .statusShowClock)
        try c.encode(statusShowFileServer, forKey: .statusShowFileServer)
        try c.encode(statusShowTransfers, forKey: .statusShowTransfers)
        try c.encode(newTabButton, forKey: .newTabButton)
        try c.encode(showHomeButton, forKey: .showHomeButton)
        try c.encode(showSearchButton, forKey: .showSearchButton)
        try c.encode(homePlace, forKey: .homePlace)
        try c.encode(launchTab, forKey: .launchTab)
        try c.encode(autoReconnect, forKey: .autoReconnect)
        try c.encode(autoPage, forKey: .autoPage)
        try c.encode(dangerGuard, forKey: .dangerGuard)
        try c.encode(safePaste, forKey: .safePaste)
        try c.encode(logSessions, forKey: .logSessions)
        try c.encode(aiEnabled, forKey: .aiEnabled)
        try c.encode(aiPanelShown, forKey: .aiPanelShown)
        try c.encode(Dictionary(uniqueKeysWithValues: features.map { ($0.key.rawValue, $0.value) }), forKey: .features)
    }
}
