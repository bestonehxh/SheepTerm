import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Files tab: this Mac | the device, a transfers strip under them, and a
/// card in the middle while connecting asks something. Icons with tooltips,
/// no captions (clean-UI rule); chrome colours like the rest of the app.
struct FilesTabView: View {
    static let margin: CGFloat = 8
    @EnvironmentObject private var files: FilesTabController

    var body: some View {
        ZStack {
            Theme.chrome.ignoresSafeArea()
            if files.phase == .connected {
                connected
            } else {
                // The SSH tab's connection card, the same view (one look for
                // every session that connects): progress, host key, login,
                // failure — driven by `FilesTabController.refreshCard`.
                CardHost(card: files.card)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.tabText)
    }

    private var connected: some View {
        VStack(spacing: 0) {
            // One margin everywhere: the window edges, the gap between the
            // panes, and the strip under them.
            HStack(spacing: Self.margin) {
                LocalPane()
                RemotePane()
            }
            .padding(Self.margin)
            if !files.transfers.isEmpty {
                TransfersStrip()
            }
        }
    }
}

// MARK: - Panes

private struct PaneHeader<Trailing: View>: View {
    let symbol: String
    let path: String
    var onUp: (() -> Void)?
    var canGoUp = true
    var onSubmit: ((String) -> Void)?
    @ViewBuilder var trailing: Trailing
    static var device: String { "sheepterm.device" }

    var body: some View {
        HStack(spacing: 6) {
            if symbol == Self.device {
                // The File Server's own glyph (style B), one device icon everywhere.
                FileServerGlyph(running: false).frame(width: 16, height: 13)
            } else {
                Image(systemName: symbol).foregroundStyle(Theme.dimText)
            }
            if let onUp {
                Button(action: onUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canGoUp)
                    .help("Enclosing folder")
            }
            if let onSubmit {
                // An address bar on both sides, as SheepDrop: click, type a
                // path (absolute, ~, or relative with ..), Return.
                EditablePathField(path: path, onGo: onSubmit)
            } else {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
                Spacer(minLength: 0)
            }
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.controlFill.opacity(0.6))
    }
}

private struct LocalPane: View {
    @EnvironmentObject private var files: FilesTabController
    @State private var selection = Set<URL>()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: "laptopcomputer", path: (files.localPath.path as NSString).abbreviatingWithTildeInPath,
                       onUp: { files.localUp() }, canGoUp: files.canGoUpLocal, onSubmit: { files.openLocalPath($0) }) {
                Button { files.chooseLocalFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Choose folder")
                Button { files.refreshLocal() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Button { files.upload(selectedFiles) } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.borderless)
                    .disabled(selectedFiles.isEmpty)
                    .help("Upload to \(files.endpoint.host)")
            }
            Table(files.localEntries, selection: $selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .lineLimit(1)
                        .onDrag { NSItemProvider(object: entry.url as NSURL) }
                }
                TableColumn("Size") { entry in
                    Text(entry.isDirectory ? "" : entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                        .foregroundStyle(Theme.dimText)
                }
                .width(min: 50, ideal: 70, max: 90)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Upload") { files.upload(Array(urls)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            } primaryAction: { urls in
                if let first = urls.first, let entry = files.localEntries.first(where: { $0.url == first }) { files.openLocal(entry) }
            }
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .onDrop(of: [.utf8PlainText], isTargeted: $dropTargeted) { providers in
                // A row dragged from the device pane: "sheepterm-remote:<name>".
                for provider in providers {
                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                        guard let text = text as? String, text.hasPrefix(RemotePane.dragPrefix) else { return }
                        let name = String(text.dropFirst(RemotePane.dragPrefix.count))
                        Task { @MainActor in
                            if let entry = files.remoteEntries.first(where: { $0.name == name }) { files.download([entry]) }
                        }
                    }
                }
                return true
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.tabActive))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? Theme.accent : Color.clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var selectedFiles: [URL] {
        files.localEntries.filter { selection.contains($0.url) && !$0.isDirectory }.map(\.url)
    }
}

private struct RemotePane: View {
    nonisolated static let dragPrefix = "sheepterm-remote:"
    @EnvironmentObject private var files: FilesTabController
    @State private var selection = Set<String>()
    @State private var dropTargeted = false
    @State private var blindPath = ""
    @State private var renaming: RemoteEntry?
    @State private var newName = ""
    @State private var askNewFolder = false

    var body: some View {
        VStack(spacing: 0) {
            if files.canBrowse {
                PaneHeader(symbol: "sheepterm.device", path: files.remotePath,
                           onUp: { files.goUp() }, canGoUp: files.canGoUp, onSubmit: { files.goTo($0) }) {
                    if files.remoteBusy { ProgressView().controlSize(.mini) }
                    Button { newName = ""; askNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).help("New folder")
                    Button { files.refreshRemote() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh")
                    Button { files.download(selectedEntries) } label: { Image(systemName: "arrow.left.circle") }
                        .buttonStyle(.borderless)
                        .disabled(selectedEntries.isEmpty)
                        .help("Download to this Mac")
                }
                browser
            } else {
                PaneHeader(symbol: "sheepterm.device", path: "\(files.protocolLabel) · \(files.endpoint.host)") { EmptyView() }
                blind
            }
            if let notice = files.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.tabActive))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? Theme.accent : Color.clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in files.upload([url], blindPath: files.canBrowse ? nil : blindPath) }
                }
            }
            return true
        }
        .alert("New folder", isPresented: $askNewFolder) {
            TextField("", text: $newName).noAutoFill()
            Button("Cancel", role: .cancel) {}
            Button("Create") { files.makeDirectory(newName) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $newName).noAutoFill()
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let renaming { files.rename(renaming, to: newName) }; renaming = nil }
        }
    }

    private var selectedEntries: [RemoteEntry] {
        files.remoteEntries.filter { selection.contains($0.id) && !$0.isDirectory }
    }

    private var browser: some View {
        Table(files.remoteEntries, selection: $selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isDirectory ? "folder" : entry.isSymlink ? "link" : "doc")
                    .lineLimit(1)
                    .onDrag { NSItemProvider(object: (Self.dragPrefix + entry.name) as NSString) }
            }
            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "" : entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                    .foregroundStyle(Theme.dimText)
            }
            .width(min: 50, ideal: 70, max: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = files.remoteEntries.filter { ids.contains($0.id) }
            Button("Download") { files.download(picked) }
                .disabled(picked.allSatisfy(\.isDirectory))
            if picked.count == 1, let one = picked.first {
                Button("Rename…") { newName = one.name; renaming = one }
            }
            Divider()
            Button("Delete…", role: .destructive) { files.remove(picked) }
        } primaryAction: { ids in
            if let id = ids.first, let entry = files.remoteEntries.first(where: { $0.id == id }) { files.open(entry) }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
    }

    /// TFTP, or SCP on a device without SFTP: name the file, get or put it.
    private var blind: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 28))
                .foregroundStyle(Theme.dimText)
            HStack(spacing: 6) {
                TextField("flash:/image.swi", text: $blindPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .noAutoFill()
                    .onSubmit { files.download(path: blindPath) }
                Button { files.download(path: blindPath) } label: { Image(systemName: "arrow.left.circle") }
                    .buttonStyle(.borderless)
                    .disabled(blindPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Get this file into the folder on the left")
                Button { choosePut() } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.borderless)
                    .help("Put a file from this Mac (named as above, or its own name)")
            }
            .frame(maxWidth: 320)
            Spacer()
        }
        .padding(12)
    }

    private func choosePut() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = files.localPath
        guard panel.runModal() == .OK, let url = panel.url else { return }
        files.upload([url], blindPath: blindPath)
    }
}

// MARK: - Transfers

private struct TransfersStrip: View {
    @EnvironmentObject private var files: FilesTabController

    var body: some View {
        VStack(spacing: 4) {
            ForEach(files.transfers.prefix(4)) { transfer in
                HStack(spacing: 6) {
                    Image(systemName: transfer.isUpload ? "arrow.right" : "arrow.left")
                        .foregroundStyle(Theme.dimText)
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                        .frame(width: 180, alignment: .leading)
                    progress(transfer)
                    Text(status(transfer))
                        .foregroundStyle(isFailed(transfer) ? Theme.warn : Theme.dimText)
                        .lineLimit(1)
                        .frame(width: 140, alignment: .trailing)
                    if transfer.state == .active || transfer.state == .queued {
                        Button { files.cancel(transfer) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Cancel")
                    }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, FilesTabView.margin + 8)
        .padding(.top, 0)
        .padding(.bottom, FilesTabView.margin)
        .contextMenu { Button("Clear Finished") { files.clearFinished() } }
    }

    @ViewBuilder private func progress(_ t: FilesTabController.Transfer) -> some View {
        if t.state == .active {
            if let total = t.total, total > 0 {
                ProgressView(value: Double(min(t.done, total)), total: Double(total)).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
        } else {
            Spacer()
        }
    }

    private func isFailed(_ t: FilesTabController.Transfer) -> Bool {
        if case .failed = t.state { return true }
        return false
    }

    private func status(_ t: FilesTabController.Transfer) -> String {
        let size = ByteCountFormatter.string(fromByteCount: t.done, countStyle: .file)
        switch t.state {
        case .queued: return String(localized: "waiting")
        case .active:
            guard let total = t.total, total > 0 else { return size }
            return "\(min(100, Int(Double(t.done) / Double(total) * 100)))% · \(size)"
        case .done: return size
        case .failed(let why): return why
        case .cancelled: return String(localized: "cancelled")
        }
    }
}

// MARK: - Connection card

/// Holds the controller's `ConnectionCardView`.
private struct CardHost: NSViewRepresentable {
    let card: ConnectionCardView

    func makeNSView(context: Context) -> FilesCardBox { FilesCardBox(card: card) }
    func updateNSView(_ nsView: FilesCardBox, context: Context) {}
}

/// The card centred in the tab or — a pane smaller than the card (a narrow
/// split) — in the SSH tab's window-centred panel (`ConnectionCardPanel`),
/// by the same rule (`ConnectionCardPlan.cardFits`), as `SessionTerminalHost`
/// places it. The panel goes when the box leaves the window (tab switched,
/// connected, closed).
final class FilesCardBox: NSView {
    let card: ConnectionCardView
    private var panel: ConnectionCardPanel?
    private var cardConstraints: [NSLayoutConstraint] = []

    init(card: ConnectionCardView) {
        self.card = card
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place()
    }

    private func place() {
        let hadKeyboard = card.hasKeyboard
        let needed = ConnectionCardView.cardSize
        guard let window else { dropPanel(); return }
        // Not laid out yet (0×0 on the first pass): no panel for a moment
        // that the real size will take back (review 6.0 (2)).
        guard bounds.width > 0, bounds.height > 0 else { dropPanel(); return }
        if ConnectionCardPlan.cardFits(card: needed, in: bounds.size) {
            dropPanel()
            card.drawsChrome = true
            guard card.superview !== self else { return }
            move(into: self, [
                card.centerXAnchor.constraint(equalTo: centerXAnchor),
                card.centerYAnchor.constraint(equalTo: centerYAnchor),
                card.widthAnchor.constraint(equalToConstant: needed.width),
                card.heightAnchor.constraint(equalToConstant: needed.height),
            ])
        } else {
            let panel = self.panel ?? {
                let made = ConnectionCardPanel(title: card.header.windowTitle)
                made.onClose = { [weak card] in card?.cancelOperation(nil) }
                self.panel = made
                return made
            }()
            card.drawsChrome = false
            if card.superview !== panel.contentView, let content = panel.contentView {
                move(into: content, [
                    card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    card.topAnchor.constraint(equalTo: content.topAnchor),
                    card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                ])
            }
            panel.setContentSize(NSSize(width: needed.width, height: needed.height + ConnectionCardView.panelTitleBand))
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                SheepAlert.center(panel, over: window)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        if hadKeyboard { card.takeKeyboard() }
    }

    private func move(into parent: NSView, _ constraints: [NSLayoutConstraint]) {
        NSLayoutConstraint.deactivate(cardConstraints)
        card.removeFromSuperview()
        parent.addSubview(card)
        cardConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    private func dropPanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// The pane's address bar (SheepDrop's `EditablePathField`): a quiet filled
/// field showing the current path; a typed path + Return goes there. Follows
/// the pane while not being edited.
struct EditablePathField: View {
    let path: String
    let onGo: (String) -> Void
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("path", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.head)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The header keeps its look (the owner: the design is right): a
            // field only shows while hovered or typed in.
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(focused ? 0.3 : hovering ? 0.15 : 0)))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            }
            .onHover { hovering = $0 }
            .help("Type a path and press Return")
            .noAutoFill()
            .onSubmit { onGo(draft); focused = false }
            .onChange(of: path) { _, newPath in if !focused { draft = newPath } }
            .onChange(of: focused) { _, isFocused in if !isFocused { draft = path } }
            .onAppear { draft = path }
    }
}
