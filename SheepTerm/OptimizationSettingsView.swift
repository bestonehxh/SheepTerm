import AppKit
import SwiftUI

/// Settings ▸ Optimization (6.1): the role presets on top, then every switch
/// that shapes the app — the same values View ▸ Sidebar / Bottom Bar / AI,
/// Edit and File already toggle (those menus stay as shortcuts). Rules in
/// `OptimizationPlan`.
struct OptimizationSettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var aiChrome = AIPanelChrome.shared
    @AppStorage(SidebarLaunch.key) private var sidebarAtLaunch = false
    @AppStorage(SidebarKeepOpen.key) private var sidebarStaysOpen = false
    @AppStorage(GroupTree.groupColorsKey) private var groupColors = GroupTree.groupColorsDefault
    @AppStorage(HostBadgeStyle.key) private var badgeStyle = HostBadgeStyle.coloured
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5
    @AppStorage(OptimizationPlan.newTabButtonKey) private var newTabButton = OptimizationPlan.NewTabButton.afterLastTab
    @AppStorage(OptimizationPlan.launchTabKey) private var launchTab = OptimizationPlan.Settings().launchTab
    @AppStorage(OptimizationPlan.showHomeButtonKey) private var showHomeButton = true
    @AppStorage(OptimizationPlan.showSearchButtonKey) private var showSearchButton = true
    @AppStorage(OptimizationPlan.homePlaceKey) private var homePlace = OptimizationPlan.HomePlace.tabStrip
    /// 6.1 (9): the Stopwatch / Rack Fill bar buttons — off unless chosen (the owner).
    @AppStorage(ToolButtonPlace.stopwatchKey) private var stopwatchPlace = ToolButtonPlace.off
    @AppStorage(ToolButtonPlace.rackFillKey) private var rackFillPlace = ToolButtonPlace.off
    @AppStorage(OptimizationPlan.Feature.keyFirst.key) private var f_keyFirst = OptimizationPlan.Feature.keyFirst.defaultOn
    @AppStorage(OptimizationPlan.Feature.jumpServers.key) private var f_jumpServers = OptimizationPlan.Feature.jumpServers.defaultOn
    @AppStorage(OptimizationPlan.Feature.forwardsInAddHost.key) private var f_forwardsInAddHost = OptimizationPlan.Feature.forwardsInAddHost.defaultOn
    @AppStorage(OptimizationPlan.Feature.telnet.key) private var f_telnet = OptimizationPlan.Feature.telnet.defaultOn
    @AppStorage(OptimizationPlan.Feature.serial.key) private var f_serial = OptimizationPlan.Feature.serial.defaultOn
    @AppStorage(OptimizationPlan.Feature.environmentTags.key) private var f_environmentTags = OptimizationPlan.Feature.environmentTags.defaultOn
    @AppStorage(OptimizationPlan.Feature.cloudDocker.key) private var f_cloudDocker = OptimizationPlan.Feature.cloudDocker.defaultOn
    @AppStorage(OptimizationPlan.Feature.deviceFamilies.key) private var f_deviceFamilies = OptimizationPlan.Feature.deviceFamilies.defaultOn
    @AppStorage(OptimizationPlan.Feature.broadcast.key) private var f_broadcast = OptimizationPlan.Feature.broadcast.defaultOn
    @AppStorage(OptimizationPlan.savedPresetsKey) private var savedData: Data?
    /// Save as Preset… (new) or Rename… (that set's id).
    @State private var naming: Naming?
    private struct Naming: Identifiable { let id = UUID(); var renaming: UUID? }
    private enum Choice: Hashable {
        case role(OptimizationPlan.Role), saved(UUID)
        var raw: String {
            switch self {
            case .role(let role): return "role:" + role.rawValue
            case .saved(let id): return "saved:" + id.uuidString
            }
        }
        init?(raw: String) {
            if raw.hasPrefix("role:"), let role = OptimizationPlan.Role(rawValue: String(raw.dropFirst(5))) { self = .role(role) }
            else if raw.hasPrefix("saved:"), let id = UUID(uuidString: String(raw.dropFirst(6))) { self = .saved(id) }
            else { return nil }
        }
    }
    @AppStorage(OptimizationPlan.builtInsKey) private var builtInsData: Data?
    /// The preset last picked (6.0 (52)): a switch changed after it keeps the
    /// row on that preset, "edited", with Save and Restore Default.
    @AppStorage("optimizationBase") private var baseRaw = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Optimize for") {
                  HStack(spacing: 4) {
                    // Segments while the names fit; a popup once saved names
                    // would push the row past the pane (Fable round 7).
                    if OptimizationPlan.fitsSegments(saved.map(\.name)) {
                        presetPicker.pickerStyle(.segmented)
                    } else {
                        presetPicker.pickerStyle(.menu).fixedSize()
                    }
                    presetButtons
                  }
                }
                .sheet(item: $naming) { item in
                    NamePromptSheet(title: item.renaming == nil ? "Save as Preset" : "Rename Preset",
                                    initialName: item.renaming.flatMap { id in saved.first { $0.id == id }?.name } ?? "") {
                        commitName($0, renaming: item.renaming)
                    }
                }
            }

            // First (the user, 6.0 (32)): what a launch opens, then the ＋.
            Section("Tab Bar") {
                Picker("At Launch", selection: $launchTab) {
                    Text("Home").tag(OptimizationPlan.LaunchTab.home)
                    Text("Terminal Tab").tag(OptimizationPlan.LaunchTab.terminal)
                }
                .pickerStyle(.segmented)
                // Chosen by hand: the user's, even back to the pinned value (Fable round 22).
                .onChange(of: launchTab) { OptimizationPlan.unpinLaunchTab(.standard) }
                Picker("New Tab Button", selection: $newTabButton) {
                    Text("After Last Tab").tag(OptimizationPlan.NewTabButton.afterLastTab)
                    Text("Far Right").tag(OptimizationPlan.NewTabButton.farRight)
                }
                .pickerStyle(.segmented)
                Toggle("Home Button", isOn: $showHomeButton)
                Picker("Home Button Place", selection: $homePlace) {
                    Text("First Tab").tag(OptimizationPlan.HomePlace.tabStrip)
                    Text("Top Bar").tag(OptimizationPlan.HomePlace.topBar)
                }
                .pickerStyle(.segmented)
                .disabled(!showHomeButton)
                Toggle("Search Button", isOn: $showSearchButton)
                    .help("⌘K still opens Quick Connect")
                Picker("Stopwatch Button", selection: $stopwatchPlace) {
                    Text("Off").tag(ToolButtonPlace.off)
                    Text("Top Bar").tag(ToolButtonPlace.topBar)
                    Text("Bottom Bar").tag(ToolButtonPlace.bottomBar)
                }
                .pickerStyle(.segmented)
                .help("Tabs ▸ Stopwatch (⌥⌘T) and a tab's right-click open it too")
                Picker("Rack Fill Button", selection: $rackFillPlace) {
                    Text("Off").tag(ToolButtonPlace.off)
                    Text("Top Bar").tag(ToolButtonPlace.topBar)
                    Text("Bottom Bar").tag(ToolButtonPlace.bottomBar)
                }
                .pickerStyle(.segmented)
                .help("Tabs ▸ Rack Fill opens it too")
            }

            Section("Sidebar") {
                Toggle("Show Sidebar at Launch", isOn: $sidebarAtLaunch)
                Toggle("Keep Sidebar Open", isOn: $sidebarStaysOpen)
                Toggle("Group Colors", isOn: $groupColors)
                Picker("Host Badges", selection: $badgeStyle) {
                    Text("Coloured").tag(HostBadgeStyle.coloured)
                    Text("Grey").tag(HostBadgeStyle.grey)
                }
                .pickerStyle(.segmented)
                Toggle("Show Recent", isOn: $showRecents)
                Stepper(value: $recentsShown, in: 1...HostStore.maxRecents) {
                    LabeledContent("Recent entries shown") {
                        Text("\(recentsShown)").font(.system(size: 12, design: .monospaced))
                    }
                }
                .disabled(!showRecents)
            }

            // View ▸ Terminal / AI / Bottom Bar, in the View menu's order and
            // with its words (the user, 6.0 (32)): one place to look, two ways in.
            Section("Terminal") {
                Toggle("Auto-page (--More--)", isOn: $model.autoPage)
                Toggle("Device Families & Highlight Packs", isOn: $f_deviceFamilies)
            }

            Section("AI") {
                Toggle("Show AI Panel", isOn: Binding(get: { aiChrome.shown }, set: { aiChrome.shown = $0 && aiChrome.enabled }))
                    .disabled(!aiChrome.enabled)
                Toggle("AI Assistant", isOn: $aiChrome.enabled)
            }

            Section("Bottom Bar") {
                Toggle("Show Bottom Bar", isOn: $model.showStatusBar)
                Picker("Connection Status", selection: $model.statusConnectionStyle) {
                    Text("Wool").tag(ConnectionIndicator.wool)
                    Text("Packet").tag(ConnectionIndicator.packet)
                    Text("Sheep").tag(ConnectionIndicator.sheep)
                    Text("Off").tag(ConnectionIndicator.off)
                }
                .pickerStyle(.segmented)
                Toggle("Session Info", isOn: $model.statusShowSession)
                Toggle("Shortcut Hints", isOn: $model.statusShowHints)
                Toggle("This Mac IP", isOn: $model.statusShowIP)
                Toggle("Clock", isOn: $model.statusShowClock)
                Toggle("File Server", isOn: $model.statusShowFileServer)
                Toggle("Transfer Progress", isOn: $model.statusShowTransfers)
            }

            Section("Connect") {
                Toggle("Key-based SSH first", isOn: $f_keyFirst)
                    .help("Add Host starts on Authentication ▸ Key when a credential has a key")
                Toggle("Port Forwards in Add Host", isOn: $f_forwardsInAddHost)
                    .help("The forwards row outside Advanced")
                // Serial, Telnet, Jump: the ＋ menu's order.
                Toggle("Serial Console & Cable Card", isOn: $f_serial)
                Toggle("Telnet", isOn: $f_telnet)
                Toggle("Jump Servers", isOn: $f_jumpServers)
                Toggle("Auto-reconnect dropped sessions", isOn: $model.autoReconnect)
            }

            Section("Hosts") {
                Toggle("Environment Tags (prod / staging / dev)", isOn: $f_environmentTags)
                Toggle("Server, Docker & Cloud Badges", isOn: $f_cloudDocker)
                    .help("SRV, DCK and CLD in the SSH badge menu")
            }

            Section("Work") {
                Toggle("Broadcast to Many Tabs", isOn: $f_broadcast)
                Toggle("Danger Command Guard", isOn: $model.confirmDangerousCommands)
                Toggle("Safe Multi-line Paste", isOn: $model.safePasteEnabled)
                Toggle("Log Sessions to File", isOn: $model.sessionLogging)
            }
        }
        .formStyle(.grouped)
        // The page is taller than the pane and scrolls: without these its
        // rows slid up under the toolbar and the traffic lights (6.0 (26)).
        .scrollEdgeEffectStyle(.hard, for: .top)
        .clipped()
    }

    private var current: OptimizationPlan.Settings {
        OptimizationPlan.Settings(
            sidebarAtLaunch: sidebarAtLaunch, sidebarStaysOpen: sidebarStaysOpen, groupColors: groupColors,
            colouredBadges: badgeStyle == .coloured,
            showRecents: showRecents, recentsShown: recentsShown,
            showStatusBar: model.showStatusBar, connectionStatus: model.statusConnectionStyle.rawValue,
            statusShowSession: model.statusShowSession, statusShowHints: model.statusShowHints,
            statusShowIP: model.statusShowIP, statusShowClock: model.statusShowClock,
            statusShowFileServer: model.statusShowFileServer, statusShowTransfers: model.statusShowTransfers,
            newTabButton: newTabButton, showHomeButton: showHomeButton, showSearchButton: showSearchButton,
            homePlace: homePlace, launchTab: launchTab,
            autoReconnect: model.autoReconnect, autoPage: model.autoPage, dangerGuard: model.confirmDangerousCommands,
            safePaste: model.safePasteEnabled, logSessions: model.sessionLogging,
            aiEnabled: aiChrome.enabled, aiPanelShown: aiChrome.shown,
            features: [.keyFirst: f_keyFirst, .jumpServers: f_jumpServers, .forwardsInAddHost: f_forwardsInAddHost,
                       .telnet: f_telnet, .serial: f_serial, .environmentTags: f_environmentTags,
                       .cloudDocker: f_cloudDocker, .deviceFamilies: f_deviceFamilies, .broadcast: f_broadcast])
    }

    private var edited: [OptimizationPlan.Role: OptimizationPlan.Settings] { OptimizationPlan.loadBuiltIns(builtInsData) }

    /// Which preset the switches match exactly (a built-in first, then a saved set).
    private var matched: Choice {
        let now = OptimizationPlan.forMatching(current, .standard)
        let role = OptimizationPlan.role(of: now, edited: edited)
        if role != .custom { return .role(role) }
        return OptimizationPlan.savedMatch(now, in: saved, edited: edited).map { .saved($0.id) } ?? .role(.custom)
    }

    /// The preset the row shows: an exact match, else the one last picked
    /// (being edited), else Custom.
    private var shown: Choice {
        if matched != .role(.custom) { return matched }
        guard let base = Choice(raw: baseRaw) else { return .role(.custom) }
        if case .saved(let id) = base, !saved.contains(where: { $0.id == id }) { return .role(.custom) }
        return base
    }

    /// The shown preset's switches were changed and not saved.
    private var isEdited: Bool { matched == .role(.custom) && shown != .role(.custom) }

    /// Picking one sets every switch and remembers it as the base.
    private var choiceBinding: Binding<Choice> {
        Binding(get: { shown },
                set: { choice in
                    baseRaw = choice.raw
                    switch choice {
                    case .role(let role): apply(OptimizationPlan.applying(role, to: current, edited: edited))
                    case .saved(let id):
                        if let set = saved.first(where: { $0.id == id }) { apply(OptimizationPlan.applying(set, to: current)) }
                    }
                })
    }

    private var presetPicker: some View {
        Picker("Optimize for", selection: choiceBinding) {
            // Named by what they do, not by a job (the user, 6.0 (50):
            // job titles were too specific).
            Text("Minimal").tag(Choice.role(.network))
            Text("Standard").tag(Choice.role(.sysadmin))
            Text("Dashboard").tag(Choice.role(.devops))
            // The user's own sets (6.0 (51)), then Custom.
            ForEach(saved) { Text($0.name).tag(Choice.saved($0.id)) }
            Text("Custom").tag(Choice.role(.custom))
        }
        .labelsHidden()
    }

    /// Beside the row: Save and Restore Default for a built-in, Save and ⋯
    /// for a saved set, ＋ (Save as Preset…) on Custom or while edited.
    @ViewBuilder private var presetButtons: some View {
        if isEdited {
            Button { saveChanges() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Save Changes")
                .accessibilityLabel("Save Changes")
        }
        if case .role(let role) = shown, role != .custom, isEdited || edited[role] != nil {
            Button { restoreDefault(role) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Restore Default")
                .accessibilityLabel("Restore Default")
        }
        if (shown == .role(.custom) || isEdited) && saved.count < OptimizationPlan.savedLimit {
            Button { naming = Naming(renaming: nil) } label: { Image(systemName: "plus") }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Save as Preset…")
                .accessibilityLabel("Save as Preset…")
        }
        if case .saved(let id) = shown {
            Button { presentMenu(for: id) } label: { Image(systemName: "ellipsis") }
                .buttonStyle(ChromeIconButtonStyle())
                .background(MenuAnchorView(box: menuAnchor))
                .help("Rename or delete this preset")
                .accessibilityLabel("Rename or delete this preset")
        }
    }

    /// Save: the shown preset takes the switches as they are now.
    private func saveChanges() {
        switch shown {
        case .role(let role) where role != .custom:
            var all = edited
            all[role] = current
            builtInsData = OptimizationPlan.encodeBuiltIns(all)
        case .saved(let id):
            var list = saved
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].settings = current; store(list) }
        default: break
        }
    }

    /// Restore Default: the shipped preset again, and the saved edit forgotten.
    private func restoreDefault(_ role: OptimizationPlan.Role) {
        var all = edited
        all[role] = nil
        // "{}", never a missing key: Sync reads a missing key as unknown and
        // would never carry the restore to the other Macs (Fable round 7).
        builtInsData = OptimizationPlan.encodeBuiltIns(all)
        baseRaw = Choice.role(role).raw
        apply(OptimizationPlan.applying(role, to: current))
    }

    private var saved: [OptimizationPlan.SavedPreset] { OptimizationPlan.loadSaved(savedData) }
    private func store(_ list: [OptimizationPlan.SavedPreset]) { savedData = OptimizationPlan.encodeSaved(list) }

    @State private var menuAnchor = MenuAnchorBox()

    /// The ⋯ beside a saved set: Rename… and Delete (an NSMenu, as the
    /// app's other icon menus — a borderless Menu drops its look).
    private func presentMenu(for id: UUID) {
        let menu = NSMenu()
        menu.addItem(MenuAction(title: String(localized: "Rename…")) { naming = Naming(renaming: id) })
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: String(localized: "Delete")) { store(saved.filter { $0.id != id }) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (menuAnchor.view?.bounds.height ?? 28) + 4), in: menuAnchor.view)
    }

    private func commitName(_ typed: String, renaming: UUID?) {
        var list = saved
        let builtIn = ["Minimal", "Standard", "Dashboard", "Custom"].flatMap { [$0, String(localized: String.LocalizationValue($0))] }
        guard let name = OptimizationPlan.uniqueName(typed, among: list, except: renaming, builtIn: builtIn) else { return }
        if let renaming, let i = list.firstIndex(where: { $0.id == renaming }) {
            list[i].name = name
        } else if list.count < OptimizationPlan.savedLimit {
            let set = OptimizationPlan.SavedPreset(name: name, settings: current)
            list.append(set)
            baseRaw = Choice.saved(set.id).raw
        }
        store(list)
    }

    private func apply(_ s: OptimizationPlan.Settings) {
        sidebarAtLaunch = s.sidebarAtLaunch
        sidebarStaysOpen = s.sidebarStaysOpen
        groupColors = s.groupColors
        badgeStyle = s.colouredBadges ? .coloured : .grey
        showRecents = s.showRecents
        recentsShown = s.recentsShown
        model.showStatusBar = s.showStatusBar
        model.statusConnectionStyle = ConnectionIndicator(rawValue: s.connectionStatus) ?? .wool
        model.statusShowSession = s.statusShowSession
        model.statusShowHints = s.statusShowHints
        model.statusShowIP = s.statusShowIP
        model.statusShowClock = s.statusShowClock
        model.statusShowFileServer = s.statusShowFileServer
        model.statusShowTransfers = s.statusShowTransfers
        newTabButton = s.newTabButton
        showHomeButton = s.showHomeButton
        showSearchButton = s.showSearchButton
        homePlace = s.homePlace
        launchTab = s.launchTab
        // Picked by the user: the launch tab is theirs, even if it is the pinned value (Fable round 21).
        OptimizationPlan.unpinLaunchTab(.standard)
        model.autoReconnect = s.autoReconnect
        model.autoPage = s.autoPage
        model.confirmDangerousCommands = s.dangerGuard
        model.safePasteEnabled = s.safePaste
        model.sessionLogging = s.logSessions
        aiChrome.enabled = s.aiEnabled
        aiChrome.shown = s.aiPanelShown && s.aiEnabled
        func on(_ f: OptimizationPlan.Feature) -> Bool { s.features[f] ?? f.defaultOn }
        f_keyFirst = on(.keyFirst); f_jumpServers = on(.jumpServers); f_forwardsInAddHost = on(.forwardsInAddHost)
        f_telnet = on(.telnet); f_serial = on(.serial); f_environmentTags = on(.environmentTags)
        f_cloudDocker = on(.cloudDocker); f_deviceFamilies = on(.deviceFamilies); f_broadcast = on(.broadcast)
    }
}
