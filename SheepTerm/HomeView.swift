import SwiftUI
import UniformTypeIdentifiers

/// Home (6.1): shown where the terminal goes when no tab is open (and at
/// launch with Settings ▸ Optimization ▸ At Launch ▸ Home). The connect field
/// on top, then the user's widgets as tiles on a fixed 4-column grid (6.1 (4):
/// like a phone's home screen — `HomePlan.Size`, `HomePlan.pack`). Edit Home
/// (the pencil) adds, sizes, filters, drags and removes widgets; the
/// board is saved (`HomePlan.storageKey`). A row is picked with one click and
/// opened with two, as in the sidebar.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = AppModel.shared.store
    @AppStorage(HomePlan.storageKey) private var stored: Data?
    /// The columns of a board from before 6.1 (4): only to size its tiles once.
    @AppStorage(HomePlan.columnsKey) private var storedColumns = 2
    @State private var editing = false
    /// The tile whose "+N more" list is open.
    @State private var expanded: UUID?
    /// "<widget>/<host>": the row picked, in that widget only.
    @State private var picked: String?
    /// "<widget>/<host>" under the pointer: the sidebar's hover band.
    @State private var hovered: String?
    /// Observed so Coloured / Grey repaints Home at once (Fable).
    @AppStorage(HostBadgeStyle.key) private var badgeStyle = HostBadgeStyle.coloured
    /// Observed so Environment Tags on/off shows at once (Fable round 4).
    @AppStorage(OptimizationPlan.Feature.environmentTags.key) private var environmentTags = OptimizationPlan.Feature.environmentTags.defaultOn
    /// The tile being dragged in Edit Home (6.1 (7)): the others make way as
    /// it passes over them, and its own spot shows as a dashed outline.
    @State private var dragging: UUID?
    @State private var addingCredential = false
    @State private var importAnchor = MenuAnchorBox()

    /// The board, every tile with its size (an old board's sized once, and
    /// saved so on the first edit).
    private var widgets: [HomePlan.Widget] {
        HomePlan.live(HomePlan.load(stored, groups: store.groups), groups: store.groups).map { widget in
            var sized = widget
            sized.size = HomePlan.size(of: widget, oldColumns: storedColumns)
            return sized
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // The search and the adding row keep their width, centred
                // (6.1 (7), the owner: a search as wide as the board is too long).
                VStack(spacing: 16) {
                    topBar
                    actionRow
                }
                .frame(maxWidth: HomePlan.boardWidth)
                // An empty host list hides outside Edit Home; the other widgets always show.
                let shown = widgets.filter { editing || !$0.source.isHostList || !hosts(for: $0).isEmpty }
                if shown.isEmpty && !editing {
                    EmptyPaneView().padding(.top, 40)
                }
                // The board takes the width it is GIVEN — what the sidebar and
                // the AI panel leave — in as many columns as fit (6.1 (7)).
                VStack(spacing: 16) {
                    BoardGridLayout(sizes: shown.map { $0.size ?? .medium }) {
                        ForEach(shown) { widget in card(widget) }
                    }
                    if editing { addMenu }
                }
                .frame(maxWidth: HomePlan.maxBoardWidth)
            }
            // Room all round, never against an edge (6.1 (8), the owner: "ต้องมีระยะเว้น").
            .padding(.horizontal, HomePlan.sideMargin)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        // NOT into the safe area: a background there spread into the titlebar
        // row and painted over the tab bar (the same trap as ContentView's chrome).
        .background(Theme.tabActive, ignoresSafeAreaEdges: [])
        .clipped()
        .sheet(isPresented: $addingCredential) {
            CredentialEditSheet(edit: CredentialEdit(credential: nil)) { addingCredential = false }
        }
    }

    /// Mockup 9 A (6.0 (41)): the adding commands, quiet — an icon and a word,
    /// no frame until the pointer is over one. The Hosts menu's names, in its
    /// order.
    private var actionRow: some View {
        HStack(spacing: 2) {
            HomeAction(symbol: "plus", title: "Add Host") { model.openAddHost() }
            HomeAction(symbol: "tablecells", title: "Add Hosts") { model.showAddHosts() }
            HomeAction(symbol: "folder.badge.plus", title: "New Group") { model.requestNewGroup() }
            HomeAction(symbol: "key", title: "Add Credential") { addingCredential = true }
            // A plain button popping an NSMenu: a SwiftUI Menu label keeps
            // its own colour and read brighter than its neighbours.
            HomeAction(symbol: "square.and.arrow.down", title: "Import") {
                let menu = NSMenu()
                menu.addItem(MenuAction(title: String(localized: "Import Group…")) { model.importGroupViaPanel() })
                menu.addItem(MenuAction(title: String(localized: "Import from Link…")) { model.showImportLink() })
                menu.addItem(MenuAction(title: String(localized: "Import Hosts File…")) { model.showAddHosts(importFile: true) })
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (importAnchor.view?.bounds.height ?? 28) + 4), in: importAnchor.view)
            }
            .background(MenuAnchorView(box: importAnchor))
            Spacer()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { model.showQuickSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13))
                    Text("Search or user@host").font(.system(size: 13))
                    Spacer()
                    Text("⌘K").font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Theme.dimText)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { editing.toggle() } label: {
                Image(systemName: editing ? "checkmark" : "pencil").font(.system(size: 13))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(editing ? Theme.accent.opacity(0.25) : Theme.controlFill))
            }
            .buttonStyle(.plain)
            .foregroundStyle(editing ? Theme.accent : Theme.dimText)
            .help(editing ? Text("Done") : Text("Edit Home"))
            .accessibilityLabel(editing ? Text("Done") : Text("Edit Home"))
        }
    }

    // MARK: cards

    private func hosts(for widget: HomePlan.Widget) -> [Host] {
        HomePlan.hosts(for: widget.source, groups: store.groups, recents: store.recents)
    }

    private func title(for source: HomePlan.Source) -> String {
        switch source {
        case .recent: return String(localized: "Recent")
        case .group(let id): return GroupTree.shownPath(of: id, in: store.groups)
        case .type, .types:
            let types = HomePlan.types(of: source)
            if types.isEmpty { return String(localized: "Hosts") }
            if Set(types) == Set(HostType.bulkTypes) { return String(localized: "All Hosts") }
            return types.map(\.badge).joined(separator: " · ")
        case .jumpServer(let id):
            let name = store.groups.flatMap(\.hosts).first { $0.id == id }?.name ?? ""
            return String(localized: "Via \(name)")
        case .clock: return String(localized: "Clock")
        case .sessions: return String(localized: "Sessions")
        case .ping: return "Ping"
        case .cables: return String(localized: "Console")
        case .snippets: return String(localized: "Snippets")
        case .logs: return String(localized: "Logs")
        case .fileServer: return String(localized: "File Server")
        case .note: return String(localized: "Note")
        case .rackFill: return "Rack Fill"
        }
    }

    /// A group by its own name (not its path); anything else as `title`.
    private func shortTitle(for source: HomePlan.Source) -> String {
        if case .group(let id) = source, let group = store.groups.first(where: { $0.id == id }) { return group.name }
        return title(for: source)
    }

    private func isTypeWidget(_ widget: HomePlan.Widget) -> Bool {
        switch widget.source {
        case .type, .types: return true
        default: return false
        }
    }

    private func card(_ widget: HomePlan.Widget) -> some View {
        let all = hosts(for: widget)
        let size = widget.size ?? .medium
        let fit = HomePlan.fit(all.count, in: size)
        let list = Array(all.prefix(fit.shown))
        return VStack(alignment: .leading, spacing: 0) {
            header(widget, count: all.count, size: size)
                .frame(height: 18)
                .padding(.bottom, 4)
            if !widget.source.isHostList {
                // Clock, Sessions, Ping, Console, Snippets, Logs, File Server, Note, Rack Fill (6.1 (8)).
                HomeWidgetBody(widget: widget, size: size) { changed in
                    update(widgets.map { $0.id == changed.id ? changed : $0 })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Edit Home: the tile drags as a whole, its game or note does not take the mouse.
                .allowsHitTesting(!editing)
            } else if size == .small {
                // 1 × 1: the count, big, in the middle of the TILE (the owner:
                // off-centre under the title) — the header's height is given back
                // below it; a click lists them.
                Spacer(minLength: 0)
                Button { expanded = widget.id } label: {
                    VStack(alignment: .center, spacing: 0) {
                        Text("\(all.count)").font(.system(size: 34, weight: .semibold).monospacedDigit())
                        Text(all.count == 1 ? String(localized: "host") : String(localized: "hosts"))
                            .font(.system(size: 11)).foregroundStyle(Theme.dimText)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show the hosts"))
            } else if size == .wide {
                // 4 × 1: two columns of rows, filled down then across.
                let half = (list.count + 1) / 2
                HStack(alignment: .top, spacing: HomePlan.gap) {
                    VStack(spacing: 0) { ForEach(list.prefix(half)) { host in row(host, in: widget) } }
                    VStack(spacing: 0) { ForEach(list.dropFirst(half)) { host in row(host, in: widget) } }
                }
            } else {
                ForEach(list) { host in row(host, in: widget) }
            }
            if widget.source.isHostList, fit.more > 0 && size != .small { moreButton(widget, more: fit.more) }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // As tall as its size, never as long as its list (6.1 (4)).
        .frame(height: size.height, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Theme.chromeLine, lineWidth: 1))
        // Where the dragged tile will land: its own spot, as a dashed outline (6.1 (7)).
        .opacity(dragging == widget.id ? 0.25 : 1)
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .opacity(dragging == widget.id ? 1 : 0))
        .popover(isPresented: Binding(get: { expanded == widget.id }, set: { if !$0 { expanded = nil } }), arrowEdge: .bottom) {
            allHosts(widget, all)
        }
        .modifier(WidgetDrag(enabled: editing, id: widget.id, title: title(for: widget.source),
                             dragging: $dragging) { over in
            // Passing over a tile: the dragged one takes its place now, the
            // rest make way — what you see is where it lands (6.1 (7), iPhone-like).
            guard let moving = dragging, moving != over else { return }
            withAnimation(.easeInOut(duration: 0.18)) { update(HomePlan.moved(widgets, id: moving, onto: over)) }
        })
    }

    /// The tile's top line: title and count; a group's ＋, a type's filter;
    /// in Edit Home the handle, the size menu and ×. A small tile keeps only
    /// the title (and its edit buttons).
    private func header(_ widget: HomePlan.Widget, count: Int, size: HomePlan.Size) -> some View {
        HStack(spacing: 6) {
            if editing && size != .small {
                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.dimText)
                    .help("Drag to move")
            }
            // A group widget wears its group's icon, in its colour (6.0 (41)).
            if case .group(let id) = widget.source, let group = store.groups.first(where: { $0.id == id }), let icon = group.icon {
                GroupIconView(icon: icon, size: 13, color: GroupIconSheet.color(group.iconColor?.rgb
                    ?? GroupTree.levelColor(depth: max(1, GroupTree.depth(of: id, in: store.groups)))))
            }
            // A small tile names a subgroup by its own name — the whole path
            // ("Head Office › Bui…") did not fit; it stays in the tooltip.
            Text(size == .small ? shortTitle(for: widget.source) : title(for: widget.source))
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .help(title(for: widget.source))
            if size != .small, widget.source.isHostList { Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.dimText) }
            Spacer(minLength: 0)
            if size != .small {
                // A type widget's filter shows at all times: it is what the widget is.
                if isTypeWidget(widget) && !editing { typeFilter(widget) }
                // A group widget adds a host straight into its group (6.0 (41)).
                if case .group(let id) = widget.source, !editing,
                   let group = store.groups.first(where: { $0.id == id }) {
                    // Into this group: one host, many, or a subgroup (6.0 (43)).
                    Menu {
                        Button("Add Host…") { model.openAddHost(inGroup: group) }
                        Button("Add Hosts…") { model.showAddHosts(groupID: group.id) }
                        Button("Add Subgroup…") { model.requestNewSubgroup(in: group) }
                            .disabled(!GroupTree.canAddChild(to: group.id, in: store.groups))
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Add to “\(group.name)”"))
                    .accessibilityLabel(String(localized: "Add to “\(group.name)”"))
                }
            }
            if editing {
                widgetMenu(widget)
                Button { update(widgets.filter { $0.id != widget.id }) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dimText)
                .help("Remove")
                .accessibilityLabel("Remove")
            }
        }
    }

    /// "+N more": the tile's whole list, in a popover.
    private func moreButton(_ widget: HomePlan.Widget, more: Int) -> some View {
        Button(String(localized: "+\(more) more")) { expanded = widget.id }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.accent)
            .frame(height: HomePlan.rowHeight - 8)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }

    /// Every host of a tile: the popover behind "+N more" and a small tile.
    private func allHosts(_ widget: HomePlan.Widget, _ all: [Host]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(for: widget.source)).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6)
            ScrollView {
                VStack(spacing: 0) { ForEach(all) { host in row(host, in: widget) } }
            }
            .frame(height: min(CGFloat(all.count) * HomePlan.rowHeight, 420))
        }
        .padding(12)
        .frame(width: 380)
    }

    /// A type widget's filter: the funnel lists every type, ticked ones shown.
    private func typeFilter(_ widget: HomePlan.Widget) -> some View {
        Menu {
            ForEach(HostType.bulkTypes) { type in
                Toggle(HostTypeMenu.label(type), isOn: typeBinding(widget.id, type))
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.dimText)
        .help("Types shown")
        .accessibilityLabel("Types shown")
    }

    /// Size and (a type widget) which types.
    private func widgetMenu(_ widget: HomePlan.Widget) -> some View {
        Menu {
            Picker("Size", selection: binding(widget.id, \.size)) {
                ForEach(HomePlan.Size.allCases, id: \.self) { size in
                    Label(Self.sizeName(size), systemImage: Self.sizeSymbol(size)).tag(Optional(size))
                }
            }
            .pickerStyle(.inline)
            if isTypeWidget(widget) {
                Divider()
                ForEach(HostType.bulkTypes) { type in
                    Toggle(HostTypeMenu.label(type), isOn: typeBinding(widget.id, type))
                }
            }
            if case .clock = widget.source {
                Divider()
                Menu(String(localized: "Time Zones")) {
                    ForEach(HomePlan.clockZones, id: \.self) { zone in
                        Toggle(HomePlan.clockCity(zone), isOn: zoneBinding(widget.id, zone))
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Size and types")
        .accessibilityLabel("Size and types")
    }

    static func sizeName(_ size: HomePlan.Size) -> String {
        switch size {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .wide: return String(localized: "Wide")
        }
    }

    static func sizeSymbol(_ size: HomePlan.Size) -> String {
        switch size {
        case .small: return "square"
        case .medium: return "rectangle"
        case .large: return "square.grid.2x2"
        case .wide: return "rectangle.split.2x1"
        }
    }

    private func row(_ host: Host, in widget: HomePlan.Widget) -> some View {
        let key = "\(widget.id)/\(host.id)"
        return HStack(spacing: 8) {
            Text(host.badge)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.badgeColor(for: host))
                .frame(width: 32, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.badgeColor(for: host).opacity(0.18)))
            Text(host.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            Text(SidebarOutlineCoordinator.detail(of: host) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dimText)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        // The sidebar's bands: picked, else under the pointer.
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(picked == key ? 0.1 : hovered == key ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
        // Two clicks open, one picks — the sidebar's rule. The pick lands on
        // the FIRST click (6.0 (43), the user: it lagged): "exclusively" waited
        // out the double-click time before it believed a single click.
        .onTapGesture(count: 2) { if !editing { picked = key; model.open(host: host) } }
        .simultaneousGesture(TapGesture().onEnded { picked = key })
    }

    // MARK: editing

    private var addMenu: some View {
        Menu {
            Button("Recent") { add(.recent) }
            Menu("Group") {
                ForEach(store.groups) { group in
                    Button(GroupTree.shownPath(of: group.id, in: store.groups)) { add(.group(group.id)) }
                }
            }
            Button("Hosts by Type") { add(.types(HostType.bulkTypes.map(\.rawValue))) }
            Divider()
            // 6.1 (8): the widgets that are not a host list.
            ForEach(Array(HomePlan.extraSources.enumerated()), id: \.offset) { _, source in
                Button(title(for: source)) { add(source) }
            }
            Divider()
            let servers = JumpTarget.jumpServers(in: store.groups)
            if !servers.isEmpty {
                Menu("Jump Server") {
                    ForEach(servers) { server in Button(server.name) { add(.jumpServer(server.id)) } }
                }
            }
            Divider()
            // Back to Recent + every top-level group.
            Button("Reset Home") { stored = nil }
        } label: {
            Label("Add Widget", systemImage: "plus")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chromeLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func add(_ source: HomePlan.Source) {
        // Each at the size it reads best at (`HomePlan.defaultSize`).
        update(widgets + [HomePlan.Widget(source: source, size: HomePlan.defaultSize(source))])
    }

    private func update(_ next: [HomePlan.Widget]) {
        stored = HomePlan.save(next)
    }

    private func binding<V>(_ id: UUID, _ path: WritableKeyPath<HomePlan.Widget, V>) -> Binding<V> {
        Binding(get: { widgets.first { $0.id == id }?[keyPath: path] ?? HomePlan.Widget(source: .recent)[keyPath: path] },
                set: { value in update(widgets.map { var w = $0; if w.id == id { w[keyPath: path] = value }; return w }) })
    }

    /// A Clock tile's zone: on or off, in the menu's order.
    private func zoneBinding(_ id: UUID, _ zone: String) -> Binding<Bool> {
        Binding(get: { widgets.first { $0.id == id }?.zones?.contains(zone) == true },
                set: { on in
                    update(widgets.map { w in
                        guard w.id == id else { return w }
                        var copy = w
                        var zones = Set(w.zones ?? [])
                        if on { zones.insert(zone) } else { zones.remove(zone) }
                        copy.zones = HomePlan.clockZones.filter(zones.contains)
                        return copy
                    })
                })
    }

    /// A type widget's filter: each type on or off; the last one cannot go.
    private func typeBinding(_ id: UUID, _ type: HostType) -> Binding<Bool> {
        Binding(get: {
                    guard let widget = widgets.first(where: { $0.id == id }) else { return false }
                    return HomePlan.types(of: widget.source).contains(type)
                },
                set: { on in
                    update(widgets.map { w in
                        guard w.id == id else { return w }
                        var types = HomePlan.types(of: w.source)
                        if on { if !types.contains(type) { types.append(type) } } else if types.count > 1 { types.removeAll { $0 == type } }
                        var copy = w
                        copy.source = .types(HostType.allCases.filter(types.contains).map(\.rawValue))
                        return copy
                    })
                })
    }
}

/// Edit Home: a tile is dragged by its body; passing over another moves it
/// there at once (the board re-packs, animated) and its spot shows dashed —
/// like rearranging a phone's home screen (6.1 (7)). Letting go anywhere
/// ends it; a drag dropped outside or cancelled is noticed when the button
/// is up. Off outside Edit Home, so a click on a row is only a click.
private struct WidgetDrag: ViewModifier {
    let enabled: Bool
    let id: UUID
    let title: String
    @Binding var dragging: UUID?
    let over: (UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = id
                    return NSItemProvider(object: (HomePlan.dragPrefix + id.uuidString) as NSString)
                } preview: {
                    Text(title).font(.system(size: 12, weight: .semibold))
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome))
                }
                .onDrop(of: [.text], delegate: WidgetDropDelegate(id: id, dragging: $dragging, over: over))
                // A drag let go outside a tile (or cancelled) never reaches a
                // drop delegate: the spot clears once the button is up.
                .task(id: dragging) {
                    guard dragging != nil else { return }
                    while !Task.isCancelled, dragging != nil {
                        try? await Task.sleep(for: .milliseconds(200))
                        if NSEvent.pressedMouseButtons == 0 { dragging = nil }
                    }
                }
        } else {
            content
        }
    }
}

private struct WidgetDropDelegate: DropDelegate {
    let id: UUID
    @Binding var dragging: UUID?
    let over: (UUID) -> Void

    func dropEntered(info: DropInfo) { over(id) }
    // Text from another app is not a tile: no "can drop" cursor (Fable).
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragging == nil ? .cancel : .move) }
    func performDrop(info: DropInfo) -> Bool {
        // Already where it shows: the moves were made on the way.
        let ours = dragging != nil
        dragging = nil
        return ours
    }
}

/// One of Home's adding buttons: a symbol and a word, a fill under the pointer.
private struct HomeAction: View {
    let symbol: String
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Theme.tabText : Theme.dimText)
        .onHover { hovering = $0 }
    }
}

/// The board (6.1 (4)): the width it is offered cut into
/// `HomePlan.gridColumns` equal columns, rows `HomePlan.unitHeight` tall,
/// each tile where `HomePlan.pack` puts it, as wide and tall as its size.
/// Never wider than offered — the tiles end flush with the search bar.
private struct BoardGridLayout: Layout {
    let sizes: [HomePlan.Size]

    private func column(_ total: CGFloat, _ columns: Int) -> CGFloat {
        max(0, (total - HomePlan.gap * CGFloat(columns - 1)) / CGFloat(columns))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HomePlan.boardWidth
        let rows = CGFloat(HomePlan.rowCount(sizes, columns: HomePlan.columns(forWidth: width)))
        return CGSize(width: width, height: max(0, rows * HomePlan.unitHeight + (rows - 1) * HomePlan.gap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = HomePlan.columns(forWidth: bounds.width)
        let col = column(bounds.width, columns)
        // Centred on the columns the tiles use: equal margins left and right.
        let used = CGFloat(HomePlan.usedColumns(sizes, columns: columns))
        let inset = max(0, (bounds.width - (used * col + max(used - 1, 0) * HomePlan.gap)) / 2)
        for ((view, size), spot) in zip(zip(subviews, sizes), HomePlan.pack(sizes, columns: columns)) {
            // A wide tile on a narrower board takes the whole row it has.
            let span = min(size.columns, columns)
            let w = col * CGFloat(span) + HomePlan.gap * CGFloat(span - 1)
            let origin = CGPoint(x: bounds.minX + inset + CGFloat(spot.column) * (col + HomePlan.gap),
                                 y: bounds.minY + CGFloat(spot.row) * (HomePlan.unitHeight + HomePlan.gap))
            view.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: w, height: size.height))
        }
    }
}
