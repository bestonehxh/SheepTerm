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
    @State private var showNewGroup = false
    @State private var renameTarget: HostGroup?
    @State private var editTarget: Host?
    /// Mirrors TopBarView's own fullscreen state — same will*-notification
    /// pattern, so the gap changes DURING the system transition.
    @State private var isFullScreen = false
    @State private var collapsedGroups: Set<UUID> = Self.loadCollapsedGroups()
    @State private var collapsedHostSections: Set<String> = Self.loadCollapsedSections()
    @State private var renameSectionTarget: SectionPrompt?
    @State private var newSectionTarget: SectionPrompt?
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5

    private static let collapsedKey = "collapsedGroups"
    /// Keys are "<groupID>/<label>" — a label alone means nothing now that a
    /// section lives inside a group and two groups may both have a "Floor 2".
    private static let collapsedSectionsKey = "collapsedHostSections"

    private static func loadCollapsedGroups() -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private static func loadCollapsedSections() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedSectionsKey) ?? [])
    }

    /// A section prompt needs an identity for `.sheet(item:)` — plus the
    /// group it is inside (for a rename) or the hosts it is about (for a new
    /// heading out of a host's menu).
    struct SectionPrompt: Identifiable {
        let id = UUID()
        var name: String = ""
        var group: HostGroup?
        var hostIDs: Set<UUID> = []
    }

    /// Shared confirmation for the sidebar's destructive actions. Defaults to
    /// Cancel so Return does not delete anything.
    private func confirmDelete(message: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        return alert.sheepStyled().runModal() == .alertSecondButtonReturn
    }

    /// The other two ways a rename can fail. Deferred a turn like
    /// `reportNameTaken`, and for the same reason: the prompt sheet is still
    /// on screen when its commit closure runs.
    private func reportRenameProblem(_ detail: String,
                                     title: String = "The section was not renamed.") {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.sheepStyled().runModal()
        }
    }

    /// HostStore refuses a duplicate group name and says nothing, so creating
    /// or renaming onto a name that is taken looked like the sheet had simply
    /// been ignored. Deferred a turn: the prompt sheet is still on screen when
    /// its commit closure runs, and an alert stacked on a sheet is a mess.
    private func reportNameTaken(_ name: String, noun: String = "group") {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The name “\(name)” is already used."
            alert.informativeText = noun == "section"
                ? "Two headings here cannot share a name."
                : "Two groups cannot share a name."
            alert.addButton(withTitle: "OK")
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
    }

    /// The same ONE-writer rule as `persistCollapsed`, for the section
    /// headings: every change to `collapsedHostSections` — a heading row
    /// toggled in the outline, a rename rekeying it, the prune below — goes
    /// through that one @State, so the `.onChange` on the outline sees all of
    /// them and nobody else writes this key.
    private func persistCollapsedSections() {
        // Sorted: a Set's order is not stable, so the plist churned on every
        // write and every backup diff looked like a change nobody made.
        UserDefaults.standard.set(collapsedHostSections.sorted(), forKey: Self.collapsedSectionsKey)
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
        // Same for section headings: one exists only as long as a host in
        // that group carries its label, so a renamed, emptied or deleted one
        // must not sit in UserDefaults forever keeping a row folded that
        // nobody can see any more.
        let liveSections = Set(store.groups.flatMap { group in
            store.sections(in: group.id).map { "\(group.id.uuidString)/\($0)" }
        })
        let prunedSections = collapsedHostSections.intersection(liveSections)
        if prunedSections != collapsedHostSections {
            collapsedHostSections = prunedSections
        }
    }

    /// Space above the search field. The sidebar owns the titlebar row, so
    /// windowed mode has to clear the traffic lights; macOS hides those in
    /// fullscreen, where the field sits flush to the top instead.
    private var topGap: CGFloat { isFullScreen ? 8 : 36 }

    /// True only when there is nothing left to fold — every group AND every
    /// section. The button reads "Expand all" exactly then; anything still
    /// open (a section with its groups folded, say) means there is more to
    /// collapse, so the first press finishes the job rather than undoing it.
    private var everythingCollapsed: Bool {
        let groupIDs = Set(store.groups.map(\.id))
        let sections = allSectionKeys
        guard !groupIDs.isEmpty || !sections.isEmpty else { return false }
        return groupIDs.isSubset(of: collapsedGroups) && sections.isSubset(of: collapsedHostSections)
    }

    /// Every heading in every group, as its collapse key.
    private var allSectionKeys: Set<String> {
        Set(store.groups.flatMap { group in
            store.sections(in: group.id).map { "\(group.id.uuidString)/\($0)" }
        })
    }

    private var searchConnectTarget: Host? {
        ConnectParser.parse(searchText)
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
            collapsedHostSections: $collapsedHostSections,
            onEditHost: { editTarget = $0 },
            onRenameGroup: { renameTarget = firstGroup(withID: $0.id) },
            onReorderGroups: { model.showReorderGroups = true },
            onDeleteGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    // Deleting a group takes every host in it. That is the
                    // largest single loss the sidebar can cause and it had no
                    // confirmation at all, while deleting one credential did.
                    guard confirmDelete(
                        message: "Delete “\(original.name)”?",
                        detail: original.hosts.isEmpty
                            ? "The group is empty."
                            : "\(original.hosts.count) host\(original.hosts.count == 1 ? "" : "s") go with it. This cannot be undone."
                    ) else { return }
                    // Forget its collapsed state too — a stale id would
                    // linger in UserDefaults forever.
                    collapsedGroups.remove(original.id)
                    store.deleteGroup(original)
                }
            },
            onExportGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    model.exportGroup(original)
                }
            },
            onAddHosts: { model.showAddHosts(groupID: $0.id) },
            onSetGroupCredential: { model.showGroupCredential(groupID: $0.id) },
            onDeleteGroups: { ids in
                // The multi-group menu asked once, for all of them.
                collapsedGroups.subtract(ids)
                store.deleteGroups(withIDs: ids)
            },
            onRenameHostSection: { group, label in
                renameSectionTarget = SectionPrompt(name: label, group: group)
            },
            onNewHostSection: { newSectionTarget = SectionPrompt(hostIDs: $0) }
        )
        // Not only on appear: a heading whose last host moves out (or a
        // Remove Section) leaves its key behind, and re-creating a heading
        // with the same name brought it back FOLDED. Idempotent, and it goes
        // through the same one writer, so running it on every store change
        // costs a set comparison.
        .onChange(of: store.revision) { _, _ in pruneCollapsedGroups() }
        .onChange(of: collapsedGroups) { _, _ in persistCollapsed() }
        .onChange(of: collapsedHostSections) { _, _ in persistCollapsedSections() }
        .onAppear {
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
        .sheet(isPresented: $showNewGroup) {
            NamePromptSheet(title: "New Group", confirmLabel: "Create") { rawName in
                // The CLEANED name, because that is what `addGroup` compares
                // and stores: a 90-character name whose first 64 characters
                // are already a group's, or "Lab\u{0}", was refused in there
                // and the sheet simply closed with nothing created.
                let name = HostStore.cleanGroupName(rawName)
                guard !name.isEmpty else {
                    reportRenameProblem("The name has no usable characters.",
                                        title: "The group was not created.")
                    return
                }
                guard !store.groups.contains(where: { $0.name == name }) else {
                    reportNameTaken(name)
                    return
                }
                store.addGroup(named: name)
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
                    reportRenameProblem("The name has no usable characters.",
                                        title: "The group was not renamed.")
                } else if store.groups.contains(where: { $0.id != group.id && $0.name == name }) {
                    reportNameTaken(name)
                }
            }
        }
        .sheet(item: $renameSectionTarget) { prompt in
            NamePromptSheet(title: "Rename Section", initialName: prompt.name) { rawName in
                guard let group = prompt.group else { return }
                // The store trims before it compares, so this has to as well:
                // renaming "Floor 2" to "Floor 2 " was reported as a name
                // that is already used.
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                // Refused when that group already has a heading by this name —
                // merging two headings silently is not what "rename" means
                // (the same rule Rename Group has).
                // The name the STORE will write, not the raw string: hygiene
                // and the snap happen in there, and the fold state and the
                // "already used" message have to talk about the same spelling
                // the file gets.
                let others = store.sections(in: group.id).filter { $0 != prompt.name }
                // What the STORE will write. nil = the name had nothing
                // usable left in it after hygiene, which is a refusal with a
                // reason, not a no-op.
                guard let written = HostStore.normalizedHeading(name, existing: others) else {
                    reportRenameProblem("The name has no usable characters.")
                    return
                }
                guard store.renameSection(in: group.id, from: prompt.name, to: name) > 0 else {
                    // Says WHY it was refused. Inner whitespace too: "Floor 2"
                    // and "Floor  2" are two rows the eye cannot tell apart.
                    let collides = others.contains {
                        $0 == written || HostStore.sameHeading($0, written)
                    }
                    if collides {
                        reportNameTaken(written, noun: "section")
                    } else if !store.sections(in: group.id).contains(prompt.name) {
                        // It was renamed or emptied in the meantime.
                        reportRenameProblem("That heading is no longer in “\(group.name)”.")
                    }
                    return
                }
                // A folded heading stays folded under its new name.
                let oldKey = "\(group.id.uuidString)/\(prompt.name)"
                if collapsedHostSections.contains(oldKey) {
                    collapsedHostSections.remove(oldKey)
                    collapsedHostSections.insert("\(group.id.uuidString)/\(written)")
                }
            }
        }
        .sheet(item: $newSectionTarget) { prompt in
            NamePromptSheet(title: "New Section", confirmLabel: "Create") { name in
                // Per host, in its own group: the label is a string, so a
                // selection spanning two groups files each side under the
                // same heading inside its own group.
                // The return value is the number of hosts filed. Zero has
                // two causes worth telling apart, and both used to close the
                // sheet as though the section had been created: a name
                // hygiene empties ("\u{1}"), and hosts that are no longer
                // there (deleted while the prompt was open).
                let filed = store.setSection(name, forHostIDs: prompt.hostIDs)
                guard filed == 0 else { return }
                if HostStore.normalizedHeading(name, existing: []) == nil {
                    reportRenameProblem("The name has no usable characters.",
                                        title: "The section was not created.")
                    return
                }
                // Zero with a usable name has a harmless cause too — every
                // selected host already reads as being under that heading —
                // so only the vanished-hosts case says anything.
                let live = store.groups.contains { group in
                    group.hosts.contains { prompt.hostIDs.contains($0.id) }
                }
                if !live {
                    reportRenameProblem("Those hosts are no longer there.",
                                        title: "The section was not created.")
                }
            }
        }
        .sheet(item: $editTarget) { host in
            HostEditSheet(host: host)
        }
    }

    /// The bottom button bar, in three widths. The sidebar is 200–320 pt and a
    /// FOURTH control (Add Hosts) no longer fits beside a spelled-out
    /// "New Group": left to itself the row pushed the folder icon off the left
    /// edge. `ViewThatFits` drops the labels instead of the buttons — widest
    /// variant first, and the help text carries the name once the word is gone.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            bottomControls(nameNewGroup: true, nameAddHosts: true, spacing: 14)
            // Tighter before anything loses its word: at the 200 pt minimum
            // the icon + "+Hosts" row measures within a point of the space
            // there is, and 14 pt of air is not worth a label.
            bottomControls(nameNewGroup: false, nameAddHosts: true, spacing: 10)
            bottomControls(nameNewGroup: false, nameAddHosts: false, spacing: 10)
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

    private func bottomControls(nameNewGroup: Bool, nameAddHosts: Bool,
                                spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                showNewGroup = true
            } label: {
                if nameNewGroup {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .font(.system(size: 11))
                        // One line, always: the label wrapped to three lines
                        // the first time a fourth control joined this row.
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Group")
            .accessibilityLabel("New Group")
            Spacer()
            Button {
                model.showAddHosts()
            } label: {
                // "+Hosts": the sign at the weight of the icons beside it, the
                // word at the size of the "New Group" label.
                // One optical weight across all four controls in this bar: the
                // plus and the folder read heavier than the two arrow glyphs
                // at `.medium`, and a row of buttons that do not match looks
                // like one of them is selected.
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .regular))
                    if nameAddHosts {
                        Text("Hosts")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 24, minHeight: 22)
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add Hosts…")
            // At the narrowest width this button is a bare "+" — which
            // VoiceOver reads as "plus", beside a "+" that makes a group.
            .accessibilityLabel("Add Hosts")
            Button {
                model.showReorderGroups = true
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reorder groups")
            .accessibilityLabel("Reorder Groups")
            Button {
                // One click, the whole tree: sections AND groups. Both sets
                // still go through their own @State (the one writer that
                // persists each), so nothing else has to know about this.
                if everythingCollapsed {
                    collapsedGroups = []
                    collapsedHostSections = []
                } else {
                    collapsedGroups = Set(store.groups.map(\.id))
                    collapsedHostSections = allSectionKeys
                }
            } label: {
                Image(systemName: everythingCollapsed
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(everythingCollapsed ? "Expand all" : "Collapse all")
            // The glyph flips with the state, so the label has to as well —
            // "Collapse all" read out over a button that expands is worse
            // than no label at all.
            .accessibilityLabel(everythingCollapsed ? "Expand All" : "Collapse All")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or user@host", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
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
                .help("Clear the search")
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
