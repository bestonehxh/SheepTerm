import AppKit
import SwiftUI

/// Sidebar chrome: search field on top, buttons on the bottom, and the row
/// list in between. The rows themselves are an NSOutlineView
/// (`SidebarOutline.swift`) — SwiftUI's List could not do drag-to-reorder
/// without the drop always looking like it drifted into place.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: HostStore
    @State private var searchText = ""
    /// ↑/↓/Return in the search field -> the outline's selection (the caret
    /// stays in the field).
    @State private var keyBridge = SidebarKeyBridge()
    /// The search field's focus lights the group level bars (`GroupTree.barsActive`).
    @FocusState private var searchFocused: Bool
    @AppStorage(GroupTree.groupColorsKey) private var groupColors = GroupTree.groupColorsDefault
    @State private var showNewGroup = false
    @State private var renameTarget: HostGroup?
    @State private var editTarget: Host?
    /// Mirrors TopBarView's own fullscreen state — same will*-notification
    /// pattern, so the gap changes DURING the system transition.
    @State private var isFullScreen = false
    @State private var collapsedGroups: Set<UUID> = Self.loadCollapsedGroups()
    /// Subgroups that are OPEN (they start shut, each opens on its own).
    @State private var openSubgroups: Set<UUID> = Self.loadOpenSubgroups()
    /// The group a "New Group…" from a group's menu makes a subgroup in.
    @State private var newSubgroupParent: HostGroup?
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5

    private static let collapsedKey = "collapsedGroups"
    private static let openSubgroupsKey = "openSubgroups"
    /// Before 6.0 (12) a SECTION's fold lived here as "<groupID>/<label>".
    /// Subgroups now start shut, so there is nothing to carry over: the key
    /// is dropped on the next write.
    private static let legacySectionsKey = "collapsedHostSections"

    private static func loadCollapsedGroups() -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private static func loadOpenSubgroups() -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: openSubgroupsKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    /// Shared confirmation for the sidebar's destructive actions. Defaults to
    /// Cancel so Return does not delete anything.
    private func confirmDelete(message: String, detail: String) -> Bool {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn
    }

    /// The other two ways a rename can fail. Deferred a turn like
    /// `reportNameTaken`, and for the same reason: the prompt sheet is still
    /// on screen when its commit closure runs.
    private func reportRenameProblem(_ detail: String,
                                     title: String = String(localized: "The group was not renamed.")) {
        DispatchQueue.main.async {
            let alert = SheepAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: String(localized: "OK"))
            alert.sheepStyled().runModal()
        }
    }

    /// Makes a group — at the top level, or a subgroup of `parent` — and
    /// says WHY when the store refuses. HostStore refuses a duplicate name
    /// and says nothing, so creating onto a name that is taken looked like
    /// the sheet had simply been ignored.
    private func createGroup(named rawName: String, in parent: HostGroup?) {
        // The CLEANED name, because that is what `addGroup` compares and
        // stores: a 90-character name whose first 64 characters are already a
        // group's, or "Lab\u{0}", was refused in there and the sheet simply
        // closed with nothing created.
        let name = HostStore.cleanGroupName(rawName)
        let failed = String(localized: "The group was not created.")
        guard !name.isEmpty else {
            reportRenameProblem(String(localized: "The name has no usable characters."), title: failed)
            return
        }
        guard !store.nameTaken(name, under: parent?.id, except: nil) else {
            reportNameTaken(name)
            return
        }
        guard store.addGroup(named: name, parent: parent?.id) != nil else {
            reportRenameProblem(parent.map { String(localized: "“\($0.name)” is no longer there, or is already \(GroupTree.userDepth) levels deep.") }
                                    ?? String(localized: "The name has no usable characters."),
                                title: failed)
            return
        }
        // A new subgroup is put where it can be seen.
        if let parent {
            collapsedGroups.remove(parent.id)
            if parent.parentID != nil, !openSubgroups.contains(parent.id) {
                openSubgroups = SidebarLayout.toggledOpen(parent.id, in: openSubgroups, groups: store.groups)
            }
        }
    }

    /// "N hosts and M subgroups go with it." — the subtree a delete takes.
    static func deleteDetail(hosts: Int, subgroups: Int) -> String {
        switch (hosts, subgroups) {
        case (0, 0): return String(localized: "The group is empty.")
        case (_, 0): return String(localized: "\(hosts) hosts go with it. This cannot be undone.")
        default: return String(localized: "\(hosts) hosts and \(subgroups) subgroups go with it. This cannot be undone.")
        }
    }

    /// HostStore refuses a duplicate group name and says nothing, so renaming
    /// onto a name that is taken looked like the sheet had simply been
    /// ignored. Deferred a turn: the prompt sheet is still on screen when its
    /// commit closure runs, and an alert stacked on a sheet is a mess.
    private func reportNameTaken(_ name: String, title: String? = nil) {
        DispatchQueue.main.async {
            let alert = SheepAlert()
            alert.alertStyle = .warning
            // The default says what is wrong with the NAME; a caller that
            // knows what failed can say that instead and put the name in the
            // line below, which is how every other refusal here reads.
            alert.messageText = title ?? String(localized: "The name “\(name)” is already used.")
            let clash = String(localized: "Two groups in one place cannot share a name.")
            alert.informativeText = title == nil ? clash : String(localized: "“\(name)” is already used here.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.sheepStyled().runModal()
        }
    }

    /// The ONE writer. Every change to `collapsedGroups` — a row toggled in
    /// the outline, the collapse-all button, a delete, the prune below — goes
    /// through the same @State, so the `.onChange` on the outline sees all of
    /// them. The call sites used to persist as well, which meant two writes
    /// for one change and one more place to forget.
    private func persistCollapsed() {
        // Sorted, like the sections twin: a Set's order is not stable, so
        // the plist churned on every write for no change anyone made.
        UserDefaults.standard.set(collapsedGroups.map(\.uuidString).sorted(),
                                  forKey: Self.collapsedKey)
        // Its sections are subgroups now, and their folds are in the line above.
        UserDefaults.standard.removeObject(forKey: Self.legacySectionsKey)
        UserDefaults.standard.set(openSubgroups.map(\.uuidString).sorted(), forKey: Self.openSubgroupsKey)
    }

    /// Drops ids of groups that no longer exist so the collapsed set
    /// can't accumulate stale UUIDs (e.g. after a delete on another
    /// running copy of the app).
    private func pruneCollapsedGroups() {
        let valid = Set(store.groups.map(\.id))
        let pruned = collapsedGroups.intersection(valid)
        if pruned != collapsedGroups {
            collapsedGroups = pruned
        }
        let openPruned = openSubgroups.intersection(valid)
        if openPruned != openSubgroups { openSubgroups = openPruned }
    }

    /// Space above the search field. The sidebar owns the titlebar row, so
    /// windowed mode has to clear the traffic lights; macOS hides those in
    /// fullscreen, where the field sits flush to the top instead.
    private var topGap: CGFloat { isFullScreen ? 8 : 36 }

    /// True only when there is nothing left to fold — every top-level group
    /// folded and no subgroup open. The button reads "Expand all" exactly
    /// then; anything still open means there is more to collapse, so the
    /// first press finishes the job rather than undoing it.
    private var everythingCollapsed: Bool {
        let tops = Set(GroupTree.children(of: nil, in: store.groups).map(\.id))
        return !tops.isEmpty && tops.isSubset(of: collapsedGroups) && openSubgroups.isEmpty
    }

    private var searchConnectTarget: Host? {
        ConnectParser.parseConnectBox(searchText)
    }

    var body: some View {
        SidebarOutline(
            store: store,
            model: model,
            searchText: searchText,
            connectTarget: searchConnectTarget,
            showRecents: showRecents,
            recentsShown: recentsShown,
            collapsedGroups: $collapsedGroups,
            openSubgroups: $openSubgroups,
            onEditHost: { host in
                // A kind this build does not know is kept, never rewritten.
                if host.kind == .unsupported { model.refuseUnsupported(host) } else { editTarget = host }
            },
            onRenameGroup: { renameTarget = firstGroup(withID: $0.id) },
            onReorderGroups: { model.showReorderGroups = true },
            onDeleteGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    // Deleting a group takes every host in it. That is the
                    // largest single loss the sidebar can cause and it had no
                    // confirmation at all, while deleting one credential did.
                    // Its subgroups go with it, so the count is the subtree's.
                    let hosts = HostStore.hostCount(ofGroupIDs: [original.id], in: store.groups)
                    let subgroups = HostStore.subgroupCount(ofGroupIDs: [original.id], in: store.groups)
                    guard confirmDelete(
                        message: String(localized: "Delete “\(original.name)”?"),
                        detail: Self.deleteDetail(hosts: hosts, subgroups: subgroups)
                    ) else { return }
                    // Forget its collapsed state too — a stale id would
                    // linger in UserDefaults forever.
                    collapsedGroups.subtract(GroupTree.subtreeIDs(of: original.id, in: store.groups))
                    store.deleteGroup(original)
                }
            },
            onExportGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    model.exportGroup(original)
                }
            },
            onShareGroup: { model.showShareLink(groupID: $0.id) },
            onAddHosts: { model.showAddHosts(groupID: $0.id) },
            onAddHost: { model.openAddHost(inGroup: $0) },
            onSetGroupCredential: { model.showGroupCredential(groupID: $0.id) },
            onDeleteGroups: { ids in
                // The multi-group menu asked once, for all of them.
                collapsedGroups.subtract(ids.flatMap { GroupTree.subtreeIDs(of: $0, in: store.groups) })
                store.deleteGroups(withIDs: ids)
            },
            onNewSubgroup: { newSubgroupParent = firstGroup(withID: $0.id) },
            groupColors: groupColors,
            keyBridge: keyBridge
        )
        // Not only on appear: a Remove Section (or a rename) leaves its key
        // behind, and making a heading with that name again brought it back
        // FOLDED. Idempotent, and it goes
        // through the same one writer, so running it on every store change
        // costs a set comparison.
        .onChange(of: store.revision) { _, _ in pruneCollapsedGroups() }
        // A restore wrote the fold keys into UserDefaults, but these two are
        // @State seeded ONCE at init: without this the restored folds never
        // appeared, and the prune above (fired by the reload's revision bump)
        // wrote the pre-restore set straight back over them. Posted before the
        // stores reload, so this runs first.
        .onReceive(NotificationCenter.default.publisher(for: .sheepTermConfigurationRestored)) { _ in
            collapsedGroups = Self.loadCollapsedGroups()
            openSubgroups = Self.loadOpenSubgroups()
        }
        .onChange(of: collapsedGroups) { _, _ in persistCollapsed() }
        .onChange(of: openSubgroups) { _, _ in persistCollapsed() }
        .onAppear {
#if DEBUG
            // SHEEPTERM_DEBUG_SHEET=edithost:<uuid> (scratch runs): Edit Host on that saved host.
            if let sheet = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_SHEET"], sheet.hasPrefix("edithost:"),
               let id = UUID(uuidString: String(sheet.dropFirst("edithost:".count))) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editTarget = model.savedHost(id: id) }
            }
            // SHEEPTERM_DEBUG_BARS_ACTIVE=n (scratch shots): the level bars lit n s in, as
            // with the pointer over the sidebar, without moving the real pointer; -n = the
            // pointer reported OUT n s in (a dim shot while the real pointer rests on the window).
            if let after = ProcessInfo.processInfo.environment["SHEEPTERM_DEBUG_BARS_ACTIVE"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + abs(after)) { keyBridge.barActivity.pointerInside = after >= 0 }
            }
#endif
            pruneCollapsedGroups()
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        // [] is load-bearing: default backgrounds auto-expand into the
        // titlebar safe area and would paint over the tab bar above.
        .background { ChromeBackground(zone: .sidebar) }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The sidebar is full height in every mode and owns the titlebar row, so the search
            // field keeps the same small top gap everywhere.
            VStack(spacing: 4) {
                Color.clear.frame(height: topGap)
                searchField
            }
            .padding(.bottom, 4)
            // [] keeps this from expanding up over the tab bar (titlebar row).
            .background { ChromeBackground(zone: .sidebar) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        // The pointer anywhere over the sidebar — list, search field, bottom
        // bar — lights the level bars; leaving dims them again.
        .onHover { inside in keyBridge.barActivity.pointerInside = inside }
        .onChange(of: searchFocused) { _, focused in keyBridge.barActivity.focusedSearch = focused }
        .sheet(isPresented: $showNewGroup) {
            NamePromptSheet(title: "New Group", confirmLabel: "Create") { rawName in
                createGroup(named: rawName, in: nil)
            }
        }
        .sheet(item: $newSubgroupParent) { parent in
            NamePromptSheet(title: "New Group", confirmLabel: "Create") { rawName in
                createGroup(named: rawName, in: parent)
            }
        }
        .sheet(item: $renameTarget) { group in
            NamePromptSheet(title: "Rename Group", initialName: group.name) { rawName in
                // Cleaned first, for the same reason as New Group above.
                let name = HostStore.cleanGroupName(rawName)
                guard !store.renameGroup(group, to: name) else { return }
                // A false result also means "the group is gone" (deleted in
                // another window), which is not worth a word.
                if name.isEmpty {
                    reportRenameProblem(String(localized: "The name has no usable characters."),
                                        title: String(localized: "The group was not renamed."))
                } else if store.nameTaken(name, under: group.parentID, except: group.id) {
                    reportNameTaken(name)
                }
            }
        }
        .sheet(item: $editTarget) { host in
            if host.kind == .web {
                WebHostSheet(mode: .edit(host))
            } else {
                HostEditSheet(host: host)
            }
        }
    }

    /// The bottom bar (5.0 (7)): the Sync account at the left (Sign In, or
    /// the user's avatar), and everything else behind one ≡ menu at the
    /// right — New Group, Add Hosts, Reorder, Expand/Collapse all. Two
    /// controls fit at the 200 pt minimum width without dropping labels.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            SyncAccountButton()
            Spacer()
            Menu {
                Button {
                    showNewGroup = true
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                Button {
                    model.openAddHost()
                } label: {
                    Label("Add Host…", systemImage: "plus")
                }
                Button {
                    model.showAddHosts()
                } label: {
                    Label("Add Hosts…", systemImage: "tablecells")
                }
                Divider()
                Button {
                    model.showReorderGroups = true
                } label: {
                    Label("Reorder Groups…", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    // Expand = every group open at every depth; Collapse =
                    // every top-level group folded and every subgroup shut.
                    if everythingCollapsed {
                        collapsedGroups = []
                        openSubgroups = Set(store.groups.filter { $0.parentID != nil }.map(\.id))
                    } else {
                        collapsedGroups = Set(GroupTree.children(of: nil, in: store.groups).map(\.id))
                        openSubgroups = []
                    }
                } label: {
                    // The glyph and the words flip with the state.
                    Label(everythingCollapsed ? String(localized: "Expand All") : String(localized: "Collapse All"),
                          systemImage: everythingCollapsed
                              ? "arrow.up.left.and.arrow.down.right"
                              : "arrow.down.right.and.arrow.up.left")
                }
            } label: {
                // Drawn, not the SF Symbol: line.3.horizontal at this size
                // packs its three strokes ~2 pt apart and reads as one block.
                // An image (template) because a Menu label shows only text
                // and images — shapes in it are dropped.
                Image(nsImage: Self.menuGlyph)
                    // The whole box opens the menu (a borderless Menu's control is its label).
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(ChromeIconBox())
            .accessibilityLabel("Groups and Hosts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background { ChromeBackground(zone: .sidebar) }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.chromeLine)
                .frame(height: 1)
        }
    }

    /// Three 14 × 1.5 pt strokes with 4 pt of air between them (2 pt read
    /// as too heavy beside the other bar glyphs).
    private static let menuGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.black.setFill()
            for y in [0.75, 6.25, 11.75] {
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: 14, height: 1.5),
                             xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or user@host", text: $searchText)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .noAutoFill()
                // Spotlight-style: ↑/↓ move the outline's selection through
                // the matches while the caret stays here, so typing goes on.
                .onKeyPress(.downArrow) {
                    keyBridge.move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    keyBridge.move(-1)
                    return .handled
                }
                .onSubmit {
                    // A host the arrows selected opens like Return in the
                    // outline; otherwise Return is what it always was.
                    if keyBridge.activateSelection() { return }
                    if let target = searchConnectTarget {
                        connect(to: target)
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { ControlFill(zone: .sidebar) }
        .padding(.horizontal, 10)
    }

    private func firstGroup(withID id: UUID) -> HostGroup? {
        store.groups.first { $0.id == id }
    }

    private func connect(to target: Host) {
        model.open(host: target)
        model.collapseSidebar()
        searchText = ""
    }
}
