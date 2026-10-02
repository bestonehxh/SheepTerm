import AppKit
import SwiftUI

/// What opens File → Known Hosts…; `search` pre-filters it (the HOST KEY
/// CHANGED offer passes the refused host).
struct KnownHostsRequest: Identifiable {
    let id = UUID()
    var search: String = ""
}

/// View and delete entries of ~/.ssh/known_hosts — the way out when a
/// device's host key really did change (reinstall, new firmware) and the
/// connection is refused. Parsing and search are `KnownHostsEditor` (pure,
/// harness-tested); the delete is `SSHWorker.removeKnownHosts`, under the
/// same locks first-use pinning takes, with a backup and an in-place
/// rewrite. /etc/ssh/ssh_known_hosts is shown read-only: it belongs to the
/// administrator.
struct KnownHostsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var search: String
    @State private var user: FileContents = .missing
    @State private var system: [KnownHostsEditor.Entry] = []
    @State private var selection: Set<Int> = []
    @State private var busy = false

    init(initialSearch: String = "") {
        _search = State(initialValue: initialSearch)
    }

    enum FileContents: Equatable {
        case missing
        case unreadable
        case loaded([KnownHostsEditor.Entry])
    }

    private static var userPath: String { SSHWorker.sshDirectory + "/known_hosts" }
    private static let shownUserPath = "~/.ssh/known_hosts"

    private var userEntries: [KnownHostsEditor.Entry] {
        if case .loaded(let entries) = user { return entries }
        return []
    }
    private var filteredUser: [KnownHostsEditor.Entry] {
        userEntries.filter { KnownHostsEditor.matches($0, query: search) }
    }
    private var filteredSystem: [KnownHostsEditor.Entry] {
        system.filter { KnownHostsEditor.matches($0, query: search) }
    }
    private var selectedEntries: [KnownHostsEditor.Entry] {
        filteredUser.filter { selection.contains($0.lineIndex) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Known Hosts")
                    .font(.headline)
                Text("Host keys you trusted, from \(Self.shownUserPath). Remove one only when you know the device's key really changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Search host, host:port or SHA256 fingerprint", text: $search)
                .textFieldStyle(.roundedBorder)

            userSection

            if !system.isEmpty {
                systemSection
            }

            HStack {
                Button(selectedEntries.count > 1 ? "Delete \(selectedEntries.count) Selected…" : "Delete Selected…") {
                    confirmDelete(selectedEntries)
                }
                .disabled(selectedEntries.isEmpty || busy)
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheepSheetChrome()
        .onAppear(perform: reload)
        // Selection is by line index, which only means something for the
        // rows on screen: a new filter starts a new selection.
        .onChange(of: search) { selection.removeAll() }
    }

    // MARK: Sections

    @ViewBuilder
    private var userSection: some View {
        switch user {
        case .missing:
            emptyText("No \(Self.shownUserPath) yet — a host key you trust is saved there on first connection.")
        case .unreadable:
            emptyText("\(Self.shownUserPath) cannot be read. SheepTerm refuses every host key until it can.", warn: true)
        case .loaded(let entries) where entries.isEmpty:
            emptyText("No host keys in \(Self.shownUserPath).")
        case .loaded:
            let rows = filteredUser
            if rows.isEmpty {
                emptyText("No host key matches “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
            } else {
                List(selection: $selection) {
                    ForEach(rows) { entry in
                        row(entry, deletable: true)
                            .tag(entry.lineIndex)
                    }
                }
                .onDeleteCommand { confirmDelete(selectedEntries) }
                .frame(height: 280)
            }
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System-wide (\(SSHWorker.globalKnownHostsPath)) — read-only; an administrator must edit it.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            let rows = filteredSystem
            if rows.isEmpty {
                Text("No system-wide entry matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(rows) { entry in
                        row(entry, deletable: false)
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 50 + 12, 120))
            }
        }
    }

    private func emptyText(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(warn ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: Row

    private func row(_ entry: KnownHostsEditor.Entry, deletable: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(of: entry))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.hashed ? "Hashed host name (\(entry.hostsField))" : entry.hostsField)
                    if let marker = entry.marker {
                        badge(marker)
                    }
                }
                HStack(spacing: 6) {
                    Text(HostKeyPromptView.keyTypeLabel(entry.keyType))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(entry.fingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.fingerprint)
                }
                Text(entry.hashed ? "hashed entry · line \(entry.lineIndex + 1)" : "line \(entry.lineIndex + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if deletable {
                Button {
                    confirmDelete([entry])
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(busy)
                .help("Remove this host key")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Fingerprint") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.fingerprint, forType: .string)
            }
            if deletable {
                Divider()
                Button("Delete…") { confirmDelete([entry]) }
                    .disabled(busy)
            }
        }
    }

    /// The host(s) as a person reads them. A hashed name cannot be shown —
    /// only what it was found by.
    private func title(of entry: KnownHostsEditor.Entry) -> String {
        if entry.hashed {
            // Shown rows matched the search, so a typed host IS this name.
            let typed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty || typed.lowercased().hasPrefix("sha256:") ? "Hashed host name" : typed
        }
        return entry.hosts.joined(separator: ", ")
    }

    private func badge(_ marker: KnownHostsEditor.Marker) -> some View {
        let revoked = marker == .revoked
        return Text(revoked ? "REVOKED" : "CERT AUTHORITY")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(revoked ? Color.red : Color.secondary)
            .overlay(Capsule().strokeBorder(revoked ? Color.red : Color.secondary, lineWidth: 1))
    }

    // MARK: Load / delete

    private func reload() {
        let path = Self.userPath
        if !FileManager.default.fileExists(atPath: path) {
            user = .missing
        } else if let data = FileManager.default.contents(atPath: path) {
            user = .loaded(KnownHostsEditor.parse(bytes: Array(data)))
        } else {
            user = .unreadable
        }
        system = FileManager.default.contents(atPath: SSHWorker.globalKnownHostsPath)
            .map { KnownHostsEditor.parse(bytes: Array($0)) } ?? []
        selection = selection.intersection(Set(userEntries.map(\.lineIndex)))
    }

    /// Asks first, in the app's centred alert; Cancel is the default
    /// (Return and Escape).
    private func confirmDelete(_ entries: [KnownHostsEditor.Entry]) {
        guard !entries.isEmpty, !busy else { return }
        let alert = SheepAlert()
        alert.alertStyle = .warning
        if entries.count == 1, let entry = entries.first {
            let shown = title(of: entry)
            let name = entry.hashed && shown == "Hashed host name" ? "this hashed entry" : shown
            alert.messageText = "Remove the host key for \(name)?"
        } else {
            alert.messageText = "Remove \(entries.count) host keys?"
        }
        var info = "The next connection will ask you to trust its key again."
        if entries.contains(where: { $0.marker == .revoked }) {
            info += " Removing a @revoked line lets that key be trusted again."
        }
        info += " A copy of the file is kept as known_hosts\(SSHWorker.knownHostsBackupSuffix)."
        alert.informativeText = info
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        delete(entries)
    }

    /// Off the main thread: the file lock may be held by another program for
    /// up to `SSHWorker.knownHostsLockWait`.
    private func delete(_ entries: [KnownHostsEditor.Entry]) {
        let identities = Set(entries.map(\.identity))
        busy = true
        Task {
            let result = await Task.detached { SSHWorker.removeKnownHosts(identities) }.value
            busy = false
            selection.removeAll()
            reload()
            if case .failed(let why) = result {
                let alert = SheepAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not remove the host key"
                alert.informativeText = why
                alert.addButton(withTitle: "OK")
                _ = alert.runModal()
            }
        }
    }
}
