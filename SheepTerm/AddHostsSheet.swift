import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Many hosts at once: a table you paste a spreadsheet into (View → Add
/// Hosts…, the sidebar button, or a group's context menu).
///
/// The parsing rules live in `BulkHostParser` (Models.swift) so they can be
/// tested without a window; this file is the table, the pickers, and the one
/// write into the store. That write is `applyImport(.merge)` — the same door
/// a `.sheepterm` import goes through — so a paste can never overwrite a host
/// that is already there, however it was typed.
struct AddHostsSheet: View {
    let request: AddHostsRequest

    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws these
    /// pickers. Same reason as HostEditSheet.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [DraftHost]
    /// Which cell has the keyboard. The grid is hand-built precisely so this
    /// works: SwiftUI's `Table` would not let a cell's TextField take focus at
    /// all (a click selected the row and the keystrokes went nowhere), and
    /// typing a list of hosts by hand is half of what this sheet is for.
    @FocusState private var focus: Field?
    /// The row the keyboard was last in — kept after focus is lost, because
    /// clicking "−" or a Paste item takes it away and "the row you are in" is
    /// exactly what those two need to know.
    @State private var activeRowID: UUID?
    /// Set to a row id to scroll it into view once (a fresh UUID every time,
    /// so the change always lands).
    @State private var scrollTarget: UUID?
    @State private var groupChoice: GroupChoice
    @State private var newGroupName = ""
    /// Applies to every row that leaves its Credential cell empty — never to
    /// one whose pasted credential text matched nothing (see
    /// `BulkHostParser.credentialChoice`).
    @State private var defaultCredentialID: UUID?
    /// What the last paste did. Plain text under the table: a paste that
    /// lands 40 rows off the bottom of the view is otherwise indistinguishable
    /// from one that landed nothing.
    @State private var status: String?

    /// Which group the hosts land in. An enum rather than `UUID?`, because
    /// nil would have to mean both "create a new one" and "nothing picked".
    private enum GroupChoice: Hashable {
        case existing(UUID)
        case new
    }

    /// One editable cell. All three are text, so Tab walks them in order and
    /// Return means the same thing in each.
    private enum Field: Hashable {
        case name(UUID)
        case address(UUID)
        case credential(UUID)
        case section(UUID)

        var rowID: UUID {
            switch self {
            case .name(let id), .address(let id), .credential(let id), .section(let id):
                return id
            }
        }
    }

    /// One row of the grid. The Credential cell is TEXT, with three meanings
    /// resolved when Add is pressed (and shown live in the cell's caption):
    /// blank = the sheet's default credential, the name or username of a saved
    /// credential = that credential, anything else = this row's username with
    /// no credential at all. Never a password — nothing in this sheet takes
    /// one.
    struct DraftHost: Identifiable, Hashable {
        let id = UUID()
        var name = ""
        var address = ""
        var credentialText = ""
        /// This host's sub-heading inside the chosen group. Blank = loose in
        /// the group. Per ROW — two rows of one paste can name two
        /// headings — and a name that does not exist yet creates it.
        var sectionText = ""
        /// The credential chosen from the cell's MENU, by id. Names are not
        /// unique, so the text alone cannot say which "core" was meant; the
        /// pick can.
        ///
        /// Cleared in ONE case only: a BLOCK paste (a tab or a second line)
        /// that WRITES this row's Credential cell (`spreadIfPasted`'s loop) —
        /// never merely because a paste started in the cell. Otherwise it
        /// is governed by the resolver's rule alone: it counts exactly while
        /// the cell holds that credential's name
        /// (`BulkHostParser.resolveCredential(_:picked:in:)`). Clearing it on
        /// every keystroke lost it on the way through intermediate text — type
        /// "x" and delete it, or ⌘X ⌘V, or ⌘Z, and the cell read "core" again
        /// with the pick gone, saving the host with the OTHER "core".
        var pickedCredentialID: UUID?

        /// Nothing typed or pasted into it yet — the rows a paste fills first.
        var isBlank: Bool {
            name.isEmpty && address.isEmpty && credentialText.isEmpty && sectionText.isEmpty
        }
    }

    /// Enough empty rows to look like a table you can type in, rather than an
    /// empty box that only accepts a paste.
    private static let initialRows = 4
    /// Far past any real host list, and still a grid that opens.
    private static let importRowCap = 2_000

    init(request: AddHostsRequest) {
        self.request = request
        _rows = State(initialValue: (0..<Self.initialRows).map { _ in DraftHost() })
        let groups = AppModel.shared.store.groups
        // Opened from a group's context menu: that group, unless it has gone.
        if let wanted = request.groupID, groups.contains(where: { $0.id == wanted }) {
            _groupChoice = State(initialValue: .existing(wanted))
        } else if let first = groups.first {
            _groupChoice = State(initialValue: .existing(first.id))
        } else {
            _groupChoice = State(initialValue: .new)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Hosts")
                .font(.headline)

            Form {
                Picker("Group", selection: $groupChoice) {
                    ForEach(model.store.groups) { group in
                        Text(group.name).tag(GroupChoice.existing(group.id))
                    }
                    Divider()
                    Text("Create New Group…").tag(GroupChoice.new)
                }
                if groupChoice == .new {
                    TextField("New group name", text: $newGroupName)
                    if newGroupNameTaken {
                        Text("The name “\(trimmedNewGroupName)” is already used.")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                Picker("Default credential", selection: $defaultCredentialID) {
                    Text("None (ask when connecting)").tag(UUID?.none)
                    ForEach(credentialStore.credentials) { credential in
                        Text("\(credential.name) (\(credential.username))")
                            .tag(UUID?.some(credential.id))
                    }
                }
                Text("Used by every row that leaves its Credential cell empty. A cell holding text that names no saved credential is that host's username instead — it does not fall back to this. Only the reference is saved — passwords stay in the Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button {
                    importFromFile()
                } label: {
                    Label("Import CSV…", systemImage: "doc.text")
                }
                .fixedSize()
                .help("Read a .csv / .tsv / .txt file — the same rules as a paste")
                Spacer()
                Button {
                    addRow()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .help("Add an empty row (or press Return in the last one)")
                .accessibilityLabel("Add row")
                Button {
                    removeActiveRow()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .disabled(rows.count <= 1)
                .help("Remove the row you are in")
                .accessibilityLabel("Remove row")
            }

            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // By id, never by index: `$rows[index]` for a row
                            // that removes itself points past the end of the
                            // array for one render, which is a crash.
                            // The row NUMBER for the accessibility labels,
                            // worked out ONCE per render: asking
                            // `firstIndex(of:)` inside each row would be a
                            // scan per row on a 2,000-row grid.
                            let numbers = rowNumbers
                            ForEach($rows) { $row in
                                gridRow($row, number: numbers[row.id] ?? 0)
                                    .id(row.id)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .bottom) }
                    }
                }
            }
            .frame(minHeight: 360)
            // A file dropped anywhere the text fields do not already claim
            // (the header, the empty area under the rows) reads the same way
            // Import CSV… does. A drop that lands ON a field is the field's —
            // AppKit gets there first and there is no fighting it.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { importFile(at: url) }
                }
                return true
            }
            .onChange(of: focus) { _, moved in
                // Remembered, not read back from `focus`: clicking "−" or a
                // Paste item clears focus, and that is exactly when those two
                // need to know which row the user was in.
                if let moved { activeRowID = moved.rowID }
            }
            // The grid is a CONTROL sitting on the sheet's glass, so it takes
            // the same opaque fill the sidebar's search field takes — a
            // translucent tint over glass reads muddy and the rows stop
            // looking like fields (the rule is written in GlassChrome.swift).
            .background { ControlFill(zone: .sheet, cornerRadius: 6) }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12))
            }

            HStack(alignment: .firstTextBaseline) {
                Text(status ?? "Type into the grid (Tab moves on, Return adds a row), ⌘V a block from a spreadsheet into a cell — it spreads out from there — or Import CSV…. A header row must use these names: Name, Host / IP, Credential, Section. A host may be written admin@host:2222.")
                    .font(.system(size: 10))
                    .foregroundStyle(status == nil ? .secondary : .primary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addLabel) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 760)
        .sheepSheetChrome()
        // ⌘V while NO cell holds the keyboard. Right after the sheet opens the
        // focus ring is drawn before the field is actually first responder
        // (measured with a real ⌘V at 1.5 s and 3 s: nothing landed until the
        // cell was clicked), and a paste that goes nowhere looks broken. The
        // paste command falls through to the view when no field editor takes
        // it, and lands here as a block from the first blank row — the same
        // path Import CSV… uses. A cell that HAS the keyboard never gets here:
        // its field editor handles ⌘V first, and `spreadIfPasted` spreads it.
        .onPasteCommand(of: [.plainText]) { _ in
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            pasteBlock(text)
        }
        .task {
            // Straight into the first cell — unless there is no group yet, in
            // which case the group's name has to be typed first.
            //
            // In `onAppear` this did nothing: the assignment lands before the
            // sheet has a window to own the first responder, so the field
            // never took focus and a ⌘V right after opening went NOWHERE —
            // measured twice, at 1.5 s and at 4 s after the sheet appeared,
            // with no focus ring on screen either. A turn later (and after
            // the first layout) it sticks.
            guard groupChoice != .new, let first = rows.first else { return }
            try? await Task.sleep(for: .milliseconds(80))
            // The sheet can be gone by now (opened and closed inside 80 ms,
            // or dismissed by Escape): focusing a field on a view that is
            // being torn down is not something to ask AppKit for.
            guard !Task.isCancelled else { return }
            focus = .name(first.id)
        }
    }

    // MARK: Grid

    /// Name and Host / IP are FLEXIBLE and absorb whatever the sheet is wide:
    /// fixed widths left ~150 pt of dead air between the last chevron and the
    /// ✕, which is what made the grid look left-heavy. Credential and Section
    /// are fixed, because a picker list beside a growing field reads badly.
    private static let nameMinWidth: CGFloat = 110
    private static let addressMinWidth: CGFloat = 170
    private static let fixedFieldWidth: CGFloat = 120
    private static let chevronWidth: CGFloat = 14
    private static let chevronGap: CGFloat = 4
    /// Field + gap + chevron: the width of a whole fixed column, and what the
    /// header label above it is given, so the two line up to the pixel.
    private static let fixedColumnWidth = fixedFieldWidth + chevronGap + chevronWidth
    private static let trailingWidth: CGFloat = 24
    private static let columnGap: CGFloat = 8

    /// ONE layout for the header and for every row. A label cannot drift off
    /// its field if both are placed by the same function — which is exactly
    /// what had happened to "Section".
    private func gridLine<A: View, B: View, C: View, D: View, E: View>(
        @ViewBuilder name: () -> A,
        @ViewBuilder address: () -> B,
        @ViewBuilder credential: () -> C,
        @ViewBuilder section: () -> D,
        @ViewBuilder trailing: () -> E
    ) -> some View {
        HStack(spacing: Self.columnGap) {
            name()
                .frame(minWidth: Self.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            // A host is longer than its name (`admin@10.0.0.1:2222`), so this
            // column starts wider and then shares the slack equally. NOT
            // `layoutPriority`: a higher priority on a `maxWidth: .infinity`
            // column takes ALL of the width and the Name column collapses to
            // nothing — measured, and it looked like the column was missing.
            address()
                .frame(minWidth: Self.addressMinWidth, maxWidth: .infinity, alignment: .leading)
            credential()
                .frame(width: Self.fixedColumnWidth, alignment: .leading)
            section()
                .frame(width: Self.fixedColumnWidth, alignment: .leading)
            // No Spacer anywhere: the two flexible columns take the slack, so
            // the ✕ sits against the right edge of the grid at any width.
            trailing()
                .frame(width: Self.trailingWidth, alignment: .center)
        }
        .padding(.horizontal, 8)
    }

    private var header: some View {
        gridLine {
            Text("Name")
        } address: {
            Text("Host / IP")
        } credential: {
            Text("Credential").help(Self.credentialRules)
        } section: {
            Text("Section").help(Self.sectionRules)
        } trailing: {
            // A bare `Color.clear` is flexible in BOTH axes and stretched the
            // header band to fill the grid — it needs a size of its own.
            Color.clear.frame(width: 1, height: 1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    /// A fixed column: its field, then its list. The chevron's space is kept
    /// even when there is no list to show, so the fields of every row stay on
    /// the same two verticals whether or not anything is saved yet.
    /// One entry of a fixed column's menu. The id is what `ForEach` keys on
    /// and what `pick` receives — for a credential that is its UUID, because
    /// two credentials can share a name AND a username, and keying the menu on
    /// its label made the second of such a pair unreachable.
    struct MenuEntry: Identifiable, Hashable {
        let id: String
        let label: String
    }

    private func fixedCell<Field: View>(menu: [MenuEntry],
                                        menuLabel: String,
                                        help: String,
                                        pick: @escaping (MenuEntry) -> Void,
                                        @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: Self.chevronGap) {
            field()
                .frame(width: Self.fixedFieldWidth)
            Group {
                if menu.isEmpty {
                    // Keeps the column's width, shows nothing: an empty menu
                    // would be a dead arrow. Sized, for the same reason the
                    // header's placeholder is.
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    Menu {
                        ForEach(menu) { entry in
                            Button(entry.label) { pick(entry) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .help(help)
                    // A chevron on its own reads as "menu" and there are two
                    // of them in every row.
                    .accessibilityLabel(menuLabel)
                }
            }
            .frame(width: Self.chevronWidth)
        }
    }

    /// id → 1-based row number, for the accessibility labels. A cell that
    /// reads as just "Name" is useless in a grid of forty of them.
    private var rowNumbers: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (offset, row) in rows.enumerated() { map[row.id] = offset + 1 }
        return map
    }

    private func gridRow(_ row: Binding<DraftHost>, number: Int) -> some View {
        let id = row.wrappedValue.id
        let meaning = meaning(of: row.wrappedValue)
        return gridLine {
            // No placeholder text in any cell: an example in every empty cell
            // reads as content, and forty of them read as a filled table.
            TextField("", text: row.name)
                .accessibilityLabel("Name, row \(number)")
                .focused($focus, equals: .name(id))
                .onSubmit { submit(from: id) }
                .onChange(of: row.wrappedValue.name) { previous, typed in
                    spreadIfPasted(typed, previous: previous, anchorRow: id, column: .name)
                }
        } address: {
            TextField("", text: row.address)
                .accessibilityLabel("Host / IP, row \(number)")
                .focused($focus, equals: .address(id))
                .onSubmit { submit(from: id) }
                .onChange(of: row.wrappedValue.address) { previous, typed in
                    spreadIfPasted(typed, previous: previous, anchorRow: id, column: .address)
                }
                // Orange when the `user@` here is the login this row will
                // use — i.e. the Default credential above does NOT apply to
                // it. Same colour, same meaning as the Credential cell's:
                // "this row asks for a password".
                .foregroundStyle(addressWarning(row.wrappedValue) == nil
                                 ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                .help(addressWarning(row.wrappedValue)
                      ?? "10.0.0.1, admin@host:2222 — a port and a user may be written here.")
        } credential: {
            fixedCell(menu: BulkHostParser.credentialMenuLabels(credentialTriples)
                        .map { MenuEntry(id: $0.id.uuidString, label: $0.label) },
                      menuLabel: "Credential list",
                      help: "Pick a saved credential — it writes its name into the cell",
                      pick: { entry in
                          // By ID: the menu shows "name (username)" and the
                          // cell holds only the NAME, which two credentials
                          // can share — so the pick is remembered beside it.
                          guard let uuid = UUID(uuidString: entry.id),
                                let picked = credentialStore.credential(for: uuid) else { return }
                          // CLEANED, defensively: names are cleaned on the way
                          // into the store now, but a credentials.json from an
                          // older build (or a hand edit) can carry a tab or a
                          // newline, and writing that into a cell reads as a
                          // block paste and spreads into the next column. The
                          // resolver compares the cleaned name too, so the
                          // pick still holds for such a name.
                          row.credentialText.wrappedValue = ConfigurationHygiene.cleanedName(picked.name)
                          row.pickedCredentialID.wrappedValue = picked.id
                      }) {
                TextField("", text: row.credentialText)
                    .accessibilityLabel("Credential, row \(number)")
                    .focused($focus, equals: .credential(id))
                    .onSubmit { submit(from: id) }
                    .onChange(of: row.wrappedValue.credentialText) { previous, typed in
                        // No clearing of the pick here: the resolver already
                        // ignores a pick whose name is not the text, so a
                        // kept pick can never describe different text — and
                        // clearing it lost it through intermediate edits.
                        spreadIfPasted(typed, previous: previous, anchorRow: id, column: .credential)
                    }
                    // What the text MEANS, without a column of its own: the
                    // caption needed ~52 pt that the grid does not have to
                    // spare, and the field can say it itself. Orange = "this
                    // is a username, not one of your credentials", which is
                    // the one outcome a user cannot see for themselves; the
                    // tooltip spells all three out.
                    .foregroundStyle(meaning == "username" ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .help(meaning.map { "\($0) — \(Self.credentialRules)" } ?? Self.credentialRules)
            }
        } section: {
            fixedCell(menu: sectionsInChosenGroup.map { MenuEntry(id: $0, label: $0) },
                      menuLabel: "Section list",
                      help: "Pick a section you already have",
                      pick: { row.sectionText.wrappedValue = $0.label }) {
                TextField("", text: row.sectionText)
                    .accessibilityLabel("Section, row \(number)")
                    .focused($focus, equals: .section(id))
                    .onSubmit { submit(from: id) }
                    .onChange(of: row.wrappedValue.sectionText) { previous, typed in
                        // A BLOCK goes to the spread WHOLE — `write` caps each
                        // value it lands. Capping here first truncated the
                        // block itself and lost its last rows. One long value
                        // is shortened in place, so the cell cannot show one
                        // spelling and file another. The rule is
                        // `BulkHostParser.sectionCellEdit`, where it is tested.
                        switch BulkHostParser.sectionCellEdit(typed) {
                        case .spread:
                            spreadIfPasted(typed, previous: previous, anchorRow: id, column: .section)
                        case .cap(let cleaned):
                            row.sectionText.wrappedValue = cleaned
                        case .keep:
                            break
                        }
                    }
                    .help(Self.sectionRules)
            }
        } trailing: {
            Button {
                remove(id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this row")
            .accessibilityLabel("Remove row \(number)")
        }
        .padding(.vertical, 3)
    }

    /// Return: on to the next row, and off the end it makes one — the same
    /// thing the "+" button does, where the hands already are.
    private func submit(from id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if index == rows.count - 1 {
            addRow()
        } else {
            focus = .name(rows[index + 1].id)
        }
    }

    private func addRow() {
        let row = DraftHost()
        rows.append(row)
        activeRowID = row.id
        focus = .name(row.id)
        scrollTarget = row.id
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if activeRowID == id { activeRowID = nil }
        // Never leave the grid with nothing to type into.
        if rows.isEmpty { rows = [DraftHost()] }
    }

    /// The row the keyboard is (or was last) in; the last row when it has
    /// never been anywhere, so the button always has an answer.
    private func removeActiveRow() {
        guard let id = activeRowID ?? rows.last?.id else { return }
        remove(id)
    }

    // MARK: Validation

    /// What the store would actually WRITE for this field — control
    /// characters out, capped, trimmed. The taken-name warning and the Add
    /// button both hang off this, so the sheet cannot say a name is free that
    /// `addGroup` will then refuse.
    private var trimmedNewGroupName: String {
        HostStore.cleanGroupName(newGroupName)
    }

    /// Case-sensitive equality, the same test `HostStore.addGroup` applies —
    /// it refuses a duplicate name and says nothing, so this sheet has to say
    /// it instead of letting Add look like it was ignored.
    private var newGroupNameTaken: Bool {
        !trimmedNewGroupName.isEmpty
            && model.store.groups.contains { $0.name == trimmedNewGroupName }
    }

    /// Rows that name a target. A row with a name and no address is someone
    /// still typing, not an error.
    private var usableRows: [DraftHost] {
        rows.filter { !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var addLabel: String {
        let count = usableRows.count
        return count == 1 ? "Add 1 Host" : "Add \(count) Hosts"
    }

    private var isValid: Bool {
        guard !usableRows.isEmpty else { return false }
        if groupChoice == .new { return !trimmedNewGroupName.isEmpty && !newGroupNameTaken }
        return true
    }

    // MARK: Paste

    private var credentialTriples: [(id: UUID, name: String, username: String)] {
        credentialStore.credentials.map { ($0.id, $0.name, $0.username) }
    }

    private func columnLabel(_ column: BulkHostParser.Column) -> String {
        switch column {
        case .name: return "Name"
        case .address: return "Host / IP"
        case .credential: return "Credential"
        case .section: return "Section"
        }
    }


    private func write(_ value: String, into row: inout DraftHost, column: BulkHostParser.Column) {
        // Every separator out, not just the ends: what makes the paste
        // detection safe is that a value in a cell can never carry one, and
        // this is the single place values are written. A tab in the middle of
        // a pasted field (a quoted TSV cell) would otherwise look like a
        // fresh block paste the next time the row was touched.
        // `storedCellValue` — the ONE definition of what a cell holds, which
        // the status line's filled/cleared counts read too. (Section gets the
        // store's name pass on top; see below.)
        let trimmed = BulkHostParser.storedCellValue(value, column: .name)
        switch column {
        case .name:
            row.name = trimmed
        case .address:
            row.address = trimmed
        case .credential:
            // Stored as typed. Resolving at paste time would have to decide
            // between a credential and a username before the user has seen
            // either, and the cell's caption says which it is anyway.
            row.credentialText = trimmed
            // The pick is NOT cleared here: the resolver decides whether it
            // still describes the text. Clearing it made a single-cell paste
            // of "core\n" behave differently from typing "core".
        case .section:
            // The STORE's pass, not `prefix(64)`: it strips control characters
            // and then caps, and doing it the other way round left the cell
            // one character shorter than the heading the store keeps — two
            // `headingKey`s for one heading, two rows in the sidebar.
            // Re-trimmed after the cap for the same reason `sectionCellEdit`
            // trims its payload: the cap can land on a space, and the store
            // trims one away — the cell has to hold the stored spelling.
            row.sectionText = BulkHostParser.storedCellValue(value, column: .section)
        }
    }

    /// A pasted row goes into the first blank row before it goes on the end:
    /// the sheet opens with four empty rows, and a paste that skipped them
    /// left the table starting with a hole the user then had to delete.
    @discardableResult
    private func place(_ row: DraftHost) -> Bool {
        if let blank = rows.firstIndex(where: \.isBlank) {
            rows[blank] = row
            return true
        }
        // The grid draws every row it holds; past the cap a paste stops
        // rather than making the sheet unusable.
        guard rows.count < Self.importRowCap else { return false }
        rows.append(row)
        return true
    }

    /// ⌘V with the cursor in a cell, the way a spreadsheet does it: the block
    /// spreads down and to the right from the cell it was pasted into.
    ///
    /// There is no paste EVENT to hook — the field is SwiftUI's — so the VALUE
    /// is the signal. Plain Tab moves focus and Return submits, so a bound
    /// value carrying a tab or a newline arrived by paste — or by a separator
    /// keystroke (⌥Return, ⌥Enter, ⌥Tab, ⌃O, ⌃⌥Return, a ⌃Q-quoted
    /// Tab/Return), which DOES put one in the field. `BulkHostParser.cellPaste`
    /// tells the two apart and such a keystroke is ignored: the cell keeps its
    /// text exactly, untrimmed. Measured in the running app: ⌘V of a
    /// spreadsheet block delivers the whole thing, tabs and newlines included,
    /// into the one cell's binding — which is what makes this work without an
    /// AppKit field of our own. (A local `NSEvent` monitor was tried first and
    /// is the wrong tool: it cannot read `@FocusState` from a closure that
    /// outlives the body, so it never knew which cell to spread from.)
    ///
    /// Re-entrant by nature and safe by the same test: every cell this writes
    /// fires its own `onChange`, and none of those values carries a separator.
    /// `previous` is the cell's text BEFORE the paste (`onChange`'s old
    /// value): the binding already holds the edited text by the time this
    /// runs, so it is the only place the anchor's old value still exists —
    /// the cell gets it back when a block does not write it (or the edit was
    /// a keystroke), and "M cells cleared" counts it when a block writes it
    /// empty.
    private func spreadIfPasted(_ typed: String, previous: String = "", anchorRow: UUID,
                                column: BulkHostParser.Column) {
        guard BulkHostParser.carriesBlockSeparators(typed) else { return }
        guard let anchor = rows.firstIndex(where: { $0.id == anchorRow }) else { return }
        // What the edit WAS — the field's whole value is not the paste. The
        // clipboard is read here only as evidence of what was inserted; the
        // decision is `BulkHostParser.cellPaste`, where it is tested.
        let text: String
        switch BulkHostParser.cellPaste(previous: previous, typed: typed,
                                        clipboard: NSPasteboard.general.string(forType: .string)) {
        case .unchanged(let text):
            // A separator TYPED, not pasted — ⌥Return, ⌥Enter, ⌥Tab, ⌃O,
            // ⌃⌥Return, a ⌃Q-quoted Tab/Return. Read as a paste it was a blank
            // row that cleared the cell (and ⌥Tab the Host beside it); instead
            // the cell gets its text back EXACTLY. Assigned RAW, not through
            // `write`: `write` trims and (for Section) cleans, so "core " +
            // ⌥Return then "sw" became "coresw". Safe raw because `text` is
            // `previous`, the cell's own last value, which never holds a
            // separator (every separator-carrying value comes through here
            // and leaves without one) — so the `onChange` this assignment
            // fires stops at the guard above.
            switch column {
            case .name: rows[anchor].name = text
            case .address: rows[anchor].address = text
            case .credential: rows[anchor].credentialText = text
            case .section: rows[anchor].sectionText = text
            }
            return
        case .single(let cell):
            // One value — a spreadsheet cell or a line copy, closed by one
            // newline; the comma in "Core, floor 3" is part of the name, not a
            // delimiter. INSERTED where the field put it, like typing it:
            // "admin@" + "10.0.0.1\n" is "admin@10.0.0.1". `write` strips the
            // newline's kin and gives Section the store's name pass.
            write(cell, into: &rows[anchor], column: column)
            return
        case .block(let pasted):
            // Only the PASTED text spreads, from the anchor, which it replaces
            // with its first value like a spreadsheet range paste. Spreading
            // the field's whole value made the text after the caret one more
            // row that silently overwrote the cell below the block
            // ("Flo|or 9" + "Floor 1\nFloor 2\n" filed "or 9" on row 3).
            text = pasted
        }
        let block = BulkHostParser.block(from: text, preservingEmptyRows: true)
        if let refused = block.rejectedHeader {
            // The anchor cell still holds the raw block at this point. It gets
            // its PREVIOUS text back, not "": nothing was pasted, so nothing
            // may be lost — a refused header in a Credential cell used to wipe
            // "netops" while the status said nothing was pasted.
            write(previous, into: &rows[anchor], column: column)
            refuseHeader(refused)
            return
        }
        // The raw block must never be left sitting in the cell it was dropped
        // in — a block with tabs and newlines in a single-line cell is what
        // must not happen. The cell gets its PREVIOUS text back, not "": a
        // block that does not write this cell (a header naming other columns,
        // a header-only paste) must leave it as it was. Writing "" here wiped
        // the name when "Host⇥Section" was pasted with the cursor in Name, and
        // wiped "netops" when a Host column was pasted in Credential — the
        // host then saved with the Default credential. A block that DOES write
        // this cell overwrites it below, as any cell it covers. (The pick is
        // left alone for the same reason: the spread clears it for every
        // Credential cell it actually writes.)
        write(previous, into: &rows[anchor], column: column)
        let (limited, note) = capped(block, anchor: anchor)
        let cells = BulkHostParser.spread(block: limited.rows, from: column, columns: limited.columns)
        guard !cells.isEmpty else {
            // The note is the REASON when there is one: at the grid's cap
            // `capped` returns no rows and " · grid is full (2000 rows)",
            // and reporting "nothing looked like a row" for a paste that was
            // perfectly good told the user the wrong thing. `pasteBlock` says
            // it the same way. (The anchor already has its previous text back,
            // so "Nothing was pasted" is literally true.)
            status = note.isEmpty ? "Nothing in that paste looked like a row." : "Nothing was pasted" + note
            return
        }
        // Worked out from the grid AS IT IS, before anything is written: which
        // cells are written at all (an empty value past the bottom of the grid
        // is not — it would append a row just to hold nothing), and what the
        // status line may honestly claim.
        let outcome = BulkHostParser.spreadOutcome(cells: cells, anchor: anchor,
                                                   anchorColumn: column, anchorPrevious: previous,
                                                   rowCount: rows.count) { row, column in
            cellText(rows[row], column)
        }
        for index in outcome.writes {
            let cell = cells[index]
            let target = anchor + cell.row
            while rows.count <= target { rows.append(DraftHost()) }
            write(cell.value, into: &rows[target], column: cell.column)
            // A BLOCK paste — anything with a tab or a second line, ONE row
            // with a tab included — that writes the Credential column ends
            // the pick of every row it writes. Kept, a row whose pick named
            // the same text saved netops while the other rows of the very
            // same paste said "core" and saved admin — visible only in a
            // tooltip. (A single plain value — `cellPaste`'s `.single`,
            // handled above — keeps the pick the same as typing it;
            // and `place`, for a paste with no cell focused, writes FRESH
            // rows, so it has no pick to end.)
            if cell.column == .credential { rows[target].pickedCredentialID = nil }
        }
        // Honest counts (`spreadOutcome`): FILLED = got a value; CLEARED = an
        // empty value replaced text that was there. An empty value over an
        // empty cell is neither, and says nothing.
        // "cleared" counts CELLS (a row that got a name while its old address
        // was emptied reports both), so the wording says cells.
        let filled = outcome.filled, cleared = outcome.cleared
        let clearedCells = "\(cleared) cell\(cleared == 1 ? "" : "s") cleared"
        let pasted: String
        if filled > 0 {
            pasted = "Pasted \(filled) row\(filled == 1 ? "" : "s")" + (cleared > 0 ? " · " + clearedCells : "")
        } else if cleared > 0 {
            pasted = "Cleared \(cleared) cell\(cleared == 1 ? "" : "s")"
        } else {
            pasted = "Nothing changed"
        }
        status = pasted + note + headerHint(limited)
    }

    /// The text a row holds in one column — what `spreadOutcome` asks, to
    /// tell a real clear from an empty value over an empty cell.
    private func cellText(_ row: DraftHost, _ column: BulkHostParser.Column) -> String {
        switch column {
        case .name: return row.name
        case .address: return row.address
        case .credential: return row.credentialText
        case .section: return row.sectionText
        }
    }

    /// What a block turned into, so the caller can say it.
    private enum Placed {
        case rows(Int)
        case column(BulkHostParser.Column, Int)
    }

    /// Said when the first row was KEPT as data but had a header's shape —
    /// several fields, no address, no name this app knows (`ชื่อ,ไอพี`). It
    /// is data, because a Floor column looks exactly the same and losing one
    /// would be worse; this is the line that stops that being a surprise.
    private func headerHint(_ block: BulkHostParser.Block) -> String {
        guard block.firstRowMayBeHeader else { return "" }
        return " · First row read as data — a header must use "
            + "Name, Host / IP, Credential, Section."
    }

    /// A header this app will not take refuses the whole paste: nothing is
    /// placed, the status line says so, and an alert names every column it
    /// could not match. Guessing was the alternative and it is silent — a
    /// sheet headed `Name,IP,Port` used to land "Name" as a host and shift
    /// every row's Port value into Credential, where it became a username.
    ///
    /// Deferred a turn, like every other alert this sheet raises: the sheet
    /// is still on screen while this runs.
    private func refuseHeader(_ names: [String]) {
        let duplicates = names.filter(BulkHostParser.isAcceptedHeading)
        let unknown = names.filter { !BulkHostParser.isAcceptedHeading($0) }
        // Short enough for the compact layout (icon centred over the text):
        // one line of message, one of detail. The expected-column list is too
        // long to keep it there, so it goes in the status line behind the
        // alert, which is still on screen when it is dismissed.
        var detail: [String] = []
        if !unknown.isEmpty {
            detail.append(unknown.count == 1
                          ? "Unknown column “\(unknown[0])”."
                          : "Unknown columns: \(unknown.joined(separator: ", ")).")
        }
        if !duplicates.isEmpty {
            detail.append(duplicates.count == 1
                          ? "“\(duplicates[0])” is used twice."
                          : "Repeated columns: \(duplicates.joined(separator: ", ")).")
        }
        status = "Header not recognised — nothing was pasted. Use \(BulkHostParser.acceptedHeadingSummary)."
        let informative = detail.joined(separator: " ")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Header not recognised"
            alert.informativeText = informative
            alert.addButton(withTitle: "OK")
            alert.sheepStyled().runModal()
        }
    }

    /// The row cap, applied wherever rows arrive in bulk. The grid draws every
    /// row it holds, so this is about the sheet staying usable, not about the
    /// source: a 40,000-line paste is as bad as a 40,000-line file.
    private func capped(_ block: BulkHostParser.Block,
                        anchor: Int? = nil) -> (block: BulkHostParser.Block, note: String) {
        // The budget is what the GRID has left, not what this block holds:
        // two 2,000-row pastes must not make a 4,000-row grid.
        let budget = BulkHostParser.rowBudget(anchor: anchor, existing: rows.count,
                                              blankRows: rows.filter(\.isBlank).count,
                                              cap: Self.importRowCap)
        guard block.rows.count > budget else { return (block, "") }
        var trimmed = block
        trimmed.rows = Array(block.rows.prefix(budget))
        // The note names what actually landed and the cap it ran into —
        // "first 2000 rows only" was a lie whenever the grid already held
        // rows and the budget was smaller than that.
        return (trimmed, BulkHostParser.capNote(placed: budget, cap: Self.importRowCap))
    }

    /// A block of parsed text becomes rows in the grid. THE one place that
    /// rule lives: a ⌘V with no cell focused and Import CSV… both come
    /// through here, so a file and the same text on the clipboard cannot
    /// drift apart.
    ///
    /// (The Excel-style ⌘V INSIDE a cell does not: it has an ANCHOR and
    /// writes outwards from it, overwriting what it covers. Same parser, same
    /// `write`, same column order — different question. Rolling it in here
    /// would mean a paste into row 7 landing in row 1.)
    private func placeBlock(_ parsed: BulkHostParser.Block) -> Placed {
        // One field per line is a COLUMN, not a table of one-column rows —
        // a list of IPs must not become 40 hosts named after their address
        // with no address at all.
        if parsed.columns == nil, parsed.rows.allSatisfy({ $0.count == 1 }) {
            let values = parsed.rows.map { $0[0] }
            let column = BulkHostParser.guessColumn(forSingleColumn: values)
            var placed = 0
            for value in values {
                var row = DraftHost()
                write(value, into: &row, column: column)
                guard place(row) else { break }
                placed += 1
            }
            return .column(column, placed)
        }
        // A header row says which column each field is; without one they are
        // read left to right off `columnOrder`.
        var placed = 0
        for fields in parsed.rows {
            var row = DraftHost()
            for (index, value) in fields.enumerated() {
                let column: BulkHostParser.Column?
                if let map = parsed.columns {
                    column = index < map.count ? map[index] : nil
                } else {
                    column = index < BulkHostParser.columnOrder.count
                        ? BulkHostParser.columnOrder[index] : nil
                }
                guard let column else { continue }
                write(value, into: &row, column: column)
            }
            guard place(row) else { break }
            placed += 1
        }
        return .rows(placed)
    }

    private func describe(_ placed: Placed, _ verb: String) -> String {
        switch placed {
        case .rows(let count):
            return "\(verb) \(count) row\(count == 1 ? "" : "s")"
        case .column(let column, let count):
            return "\(verb) \(count) \(columnLabel(column)) value\(count == 1 ? "" : "s")"
        }
    }

    // MARK: Import a file

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(at: url)
    }

    /// A block pasted with no cell focused: blank rows first, then the end —
    /// what a paste into the sheet rather than into a cell means.
    private func pasteBlock(_ text: String) {
        // One plain line and no tab is ONE value, comma and all. Without it a
        // name like "Core, floor 3" pasted into the sheet was split at the
        // comma into two columns. `skippingBlankLines`: this paste has no
        // cell to keep coordinates for, so the blank lines Excel puts round a
        // single cell ("Core, floor 3\n\n") do not turn it into a block.
        if let value = BulkHostParser.singleValue(ifPlain: text, skippingBlankLines: true) {
            let column = BulkHostParser.guessColumn(forSingleColumn: [value])
            var row = DraftHost()
            write(value, into: &row, column: column)
            if place(row) {
                status = "Pasted 1 \(columnLabel(column)) value"
            } else {
                status = "Nothing was pasted" + BulkHostParser.capNote(placed: 0,
                                                                         cap: Self.importRowCap)
            }
            return
        }
        let block = BulkHostParser.block(from: text)
        if let refused = block.rejectedHeader {
            refuseHeader(refused)
            return
        }
        guard !block.isEmpty else {
            status = "Nothing in the clipboard looked like a row."
            return
        }
        let (parsed, note) = capped(block)
        status = describe(placeBlock(parsed), "Pasted") + note + headerHint(parsed)
    }

    /// A file goes through exactly the path a paste does — same parser, same
    /// placement — so "it worked from the clipboard but not from the file" is
    /// not a thing that can happen.
    private func importFile(at url: URL) {
        let name = url.lastPathComponent
        // Asked BEFORE the file is read: a host list is a few hundred lines,
        // and reading whatever was dropped here whole, on main, cost ten
        // seconds and 780 MB on a 64 MB file before the content gate below
        // got to say no.
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard BulkHostParser.importSizeAllowed(bytes: bytes) else {
            status = "\(name) is too large to be a host list."
            return
        }
        guard let text = Self.readText(at: url) else {
            // Said in the status line, not an alert: the sheet is already on
            // screen and a modal over a sheet for "wrong file" is a lot.
            status = "Could not read \(name)"
            return
        }
        let parsed = BulkHostParser.block(from: text)
        if let refused = parsed.rejectedHeader {
            refuseHeader(refused)
            return
        }
        // Most of a host list is hosts — asked of the COLUMN that holds
        // them, not of every field: counting `looksLikeAddress` per field
        // refused a perfectly good CSV of `core-sw-01` hostnames, which have
        // no dots in them at all.
        if !parsed.rows.isEmpty, !BulkHostParser.looksLikeHostList(parsed, text: text) {
            status = "This doesn't look like a host list — \(name) was not imported."
            return
        }
        // A cap, because the grid is a view of every row at once: 2,000 is
        // far past any real list and still opens.
        guard !parsed.isEmpty else {
            status = "Nothing in \(name) looked like a row."
            return
        }
        let (limited, note) = capped(parsed)
        status = "\(describe(placeBlock(limited), "Imported")) from \(name)"
            + note + headerHint(limited)
    }

    /// The file's bytes as text — `BulkHostParser.decodeImport` decides the
    /// encoding: UTF-16 by its byte-order mark first (Excel's "UTF-16 Unicode
    /// Text", Numbers' UTF-16 CSV), then UTF-8, then Latin-1 as the last
    /// resort. Latin-1 decodes ANY byte sequence, so this fails only when the
    /// file cannot be read at all, which is the one case worth reporting.
    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return BulkHostParser.decodeImport(data)
    }

    // MARK: Add

    static let sectionRules = """
        The sub-heading this host sits under INSIDE the group — a floor, a \
        rack, a role. Leave it empty and the host sits loose in the group. A \
        name you already use files it under that heading; anything else \
        creates the heading. Per row: two hosts in one paste can go under \
        two different headings.
        """

    /// The headings that already exist in the group this batch is going to —
    /// the chevron offers those, and typing anything else makes a new one.
    /// `sections(in:)` is `HostGroup.displayedSections`, so an EMPTY heading
    /// the user made in that group is offered here like any other.
    private var sectionsInChosenGroup: [String] {
        switch groupChoice {
        case .existing(let id): return model.store.sections(in: id)
        case .new: return []
        }
    }

    static let credentialRules = """
        Leave it empty to use the Default credential above. \
        Type the name or the username of a saved credential to use that one. \
        Any other text is this host's username on its own — no credential, \
        so connecting asks for a password. A credential named here also wins \
        over a user@ written in the Host / IP cell.
        """

    /// What the Credential cell's text resolves to: the credential this row
    /// will use, and the username to save when it is not one of ours.
    ///
    /// The candidates are looked up before the choice is made, so a stale id
    /// (a credential deleted from under the sheet) counts as absent rather
    /// than travelling into hosts.json pointing at nothing;
    /// `BulkHostParser.credentialChoice` then applies the rule the three
    /// meanings come from — text that names no saved credential does NOT fall
    /// back to the default, it is a different login.
    private func resolved(_ row: DraftHost) -> (credential: Credential?, username: String) {
        let text = row.credentialText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The PICK first (by id, while it still describes the cell), then the
        // text rules — one pure function, tested in the harness.
        let matched = BulkHostParser.resolveCredential(text, picked: row.pickedCredentialID,
                                                       in: credentialTriples)
            .flatMap { credentialStore.credential(for: $0)?.id }
        let typedUsername = matched == nil ? text : ""
        let fallback = credentialStore.credential(for: defaultCredentialID)
        let chosen = BulkHostParser.credentialChoice(
            rowCredential: matched,
            pastedUsername: typedUsername,
            // A `user@` in the Host / IP cell is a login the user wrote; the
            // default credential is the blanket answer for rows that said
            // nothing, and it does not get to overrule one.
            addressUser: BulkHostParser.addressUser(row.address),
            defaultCredential: fallback?.id,
            defaultUsername: fallback?.username ?? ""
        )
        return (credentialStore.credential(for: chosen), typedUsername)
    }

    /// True when this row's `user@` is what decides its login, because it
    /// names someone other than the default credential's user. The Host / IP
    /// field is coloured for it: the row is NOT getting the default, and that
    /// is the one thing the cells alone do not say.
    private func addressUserWins(_ row: DraftHost) -> Bool {
        guard row.credentialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let fallback = credentialStore.credential(for: defaultCredentialID) else { return false }
        let user = BulkHostParser.addressUser(row.address)
        return !user.isEmpty && user != fallback.username
    }

    /// The other side of the same question: this row's Credential cell names
    /// a credential whose username is NOT the `user@` written in the address.
    /// The cell wins (it carries the password), but silently overruling
    /// something the user typed is how `netops@10.0.0.1` came to log in as
    /// admin — so the address is marked.
    private func credentialBeatsAddressUser(_ row: DraftHost) -> Bool {
        let text = row.credentialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let id = BulkHostParser.resolveCredential(text, picked: row.pickedCredentialID,
                                                        in: credentialTriples),
              let credential = credentialStore.credential(for: id) else { return false }
        let user = BulkHostParser.addressUser(row.address)
        return !user.isEmpty && user != credential.username
    }

    /// Why this row's Host / IP field is marked, or nil when it is not.
    private func addressWarning(_ row: DraftHost) -> String? {
        if addressUserWins(row) {
            return "The user@ in this address wins over the Default credential — this host will ask for a password."
        }
        if credentialBeatsAddressUser(row) {
            return "The Credential cell's login wins over the user@ in the address."
        }
        return nil
    }

    /// The caption beside the cell: the credential's own username when the
    /// text names one of ours, the word "username" when it does not, and
    /// nothing at all when the cell is empty (the Default row above already
    /// says what empty means).
    private func meaning(of row: DraftHost) -> String? {
        let trimmed = row.credentialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let id = BulkHostParser.resolveCredential(trimmed, picked: row.pickedCredentialID,
                                                        in: credentialTriples),
              let credential = credentialStore.credential(for: id) else { return "username" }
        return credential.username.isEmpty ? "credential" : credential.username
    }

    private func add() {
        var hosts: [Host] = []
        var skipped = 0
        var repeated = 0
        for row in usableRows {
            let (chosen, typedUsername) = resolved(row)
            let label = row.sectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = BulkHostParser.makeHost(
                name: row.name,
                address: row.address,
                credentialID: chosen?.id,
                credentialUsername: chosen?.username,
                pastedUsername: typedUsername,
                section: label.isEmpty ? nil : label
            ) else {
                skipped += 1
                continue
            }
            hosts.append(host)
        }

        // Every row was unusable: there is nothing to add, and creating an
        // empty group for it would be worse than saying so.
        guard !hosts.isEmpty else {
            dismiss()
            report(added: 0, existed: 0, skipped: skipped, repeated: repeated,
                   group: nil, filed: (hosts: 0, sections: 0), hygiene: nil)
            return
        }

        // The same pass an import or a restore gets: a name is shortened, a
        // control character is stripped, nothing is dropped. What changed is
        // REPORTED only for the rows that are written (see below) — the raw
        // rows are kept for that.
        let rawRows = hosts
        _ = ConfigurationHygiene.sanitize(&hosts)
        // Two rows for the same connection are one host — counted AFTER
        // hygiene, because that is when two rows can BECOME the same
        // connection (a stripped control character in an address). Doing it
        // before meant those two landed as one and the extra was reported as
        // "already existed", which it never was.
        let unique = BulkHostParser.deduped(hosts)
        repeated += hosts.count - unique.count
        hosts = unique
        // Counted AFTER hygiene and only over what is new to the target
        // group: a paste where eleven of twelve rows were already there
        // filed nothing, whatever the cells said.
        let existing: [Host]
        switch groupChoice {
        case .existing(let id): existing = model.store.hosts(inGroup: id)
        case .new: existing = []
        }
        // `declared` as well: an EMPTY heading in the target group is a real
        // heading, and a row typed as "floor  2" joins it exactly as it will
        // when the store writes it.
        let filed = BulkHostParser.filedSummary(hosts: hosts, existing: existing,
                                                declared: sectionsInChosenGroup)
        // Only the rows that land: a correction to a row whose target was
        // already in the group never reached anything, and saying it did was
        // a report about data that was not written.
        let hygiene = BulkHostParser.hygieneReport(forRows: rawRows, landingIn: existing)

        let stats: GroupImportStats
        let groupName: String
        switch groupChoice {
        case .existing(let id):
            guard let group = model.store.groups.first(where: { $0.id == id }) else {
                dismiss()
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "That group no longer exists."
                    alert.informativeText = "Nothing was added."
                    alert.addButton(withTitle: "OK")
                    alert.sheepStyled().runModal()
                }
                return
            }
            groupName = group.name
            // `.merge`: hosts whose address+port+username is new are appended
            // and everything already there is left exactly as it is. A paste
            // must never overwrite a host someone configured by hand.
            stats = model.store.applyImport(
                HostGroup(id: group.id, name: group.name, hosts: hosts),
                action: .merge,
                replace: [:]
            )
            // Each host carries its own heading (`Host.section`), so
            // `applyImport` files them as it adds them — nothing to apply
            // afterwards, and a host that was already there keeps the heading
            // it had.
        case .new:
            groupName = trimmedNewGroupName
            // A taken name was already refused above, so `uniqueGroupName`
            // inside applyImport has nothing to renumber.
            stats = model.store.applyImport(
                HostGroup(name: groupName, hosts: hosts),
                action: .createNew,
                replace: [:]
            )
        }

        dismiss()
        report(added: stats.addedHosts,
               existed: hosts.count - stats.addedHosts,
               skipped: skipped,
               repeated: repeated,
               // The name the STORE used: hygiene caps it at 64 characters
               // and `uniqueGroupName` may have renumbered it, so the name
               // typed into the field is not always the name that exists.
               group: stats.groupName ?? groupName,
               filed: filed,
               hygiene: hygiene.summary)
    }

    /// Said out loud, because "Add 13 Hosts" landing 11 of them is exactly
    /// the kind of quiet difference someone finds a week later.
    /// Deferred a turn like `SidebarView.reportNameTaken`: the sheet is still
    /// on screen while this runs, and an alert stacked on a sheet is a mess.
    private func report(added: Int, existed: Int, skipped: Int, repeated: Int,
                        group: String?, filed: (hosts: Int, sections: Int), hygiene: String?) {
        // The COUNT goes on the message line and the rest stays short: an
        // alert whose text block runs past ~3 lines is laid out the wide way,
        // with the icon shoved to the left (measured — see `sheepStyled`).
        let message = group.map { "Added \(added) host\(added == 1 ? "" : "s") to “\($0)”." }
            ?? "No hosts were added."
        // ONE line for everything, zeros left out, and the words kept short:
        // measured (see `NSAlert.sheepStyled`) — "4 filed · 2 existed · 1
        // repeated · 1 skipped." is 45 characters and stays compact, while
        // the same facts as three sentences wrapped past the third rendered
        // line and took the icon to the left with them. A very long group
        // name on the message line can still push it wide; the name is worth
        // more there than the layout.
        var counts: [String] = []
        if added > 0, filed.hosts > 0 {
            // On its own it can say where they went; beside other counts it
            // has to be two words or the alert loses the compact layout
            // (measured — see `NSAlert.sheepStyled`).
            let alone = existed == 0 && repeated == 0 && skipped == 0
            counts.append(alone
                          ? "\(filed.hosts) filed under \(filed.sections) "
                            + "section\(filed.sections == 1 ? "" : "s")"
                          : "\(filed.hosts) filed")
        }
        if existed > 0 { counts.append("\(existed) existed") }
        if repeated > 0 { counts.append("\(repeated) repeated") }
        if skipped > 0 { counts.append("\(skipped) skipped") }
        var detail: [String] = []
        if !counts.isEmpty { detail.append(counts.joined(separator: " · ") + ".") }
        // The hygiene report is the one part that cannot be short: it names
        // every correction made to the user's own data, so it is allowed to
        // push this alert into the wide layout on the rare run that has one.
        let informative = (detail + (hygiene.map { [$0] } ?? [])).joined(separator: "\n")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = message
            alert.informativeText = informative
            alert.addButton(withTitle: "OK")
            alert.sheepStyled().runModal()
        }
    }
}
