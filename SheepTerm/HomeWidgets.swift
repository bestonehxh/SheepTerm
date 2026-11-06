import SwiftUI

/// The Home tiles that are not a host list (6.1 (8), the owner: "ชอบหมดเลย
/// เอาทั้งหมด"): Clock, Sessions, Ping, Console, Snippets, Logs, File Server,
/// Note and Rack Fill. Each reads what the app already has; a small tile
/// shows one number, larger ones a list. Nothing here ticks while nothing
/// changes, except the Clock (once a minute) and a transfer's bar.
struct HomeWidgetBody: View {
    let widget: HomePlan.Widget
    let size: HomePlan.Size
    /// Writes the widget back (a Note's text).
    let update: (HomePlan.Widget) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch widget.source {
        case .clock: ClockTile(zones: widget.zones ?? [], size: size)
        case .sessions: SessionsTile(size: size)
        case .ping: PingTile(size: size)
        case .cables: ConsoleTile(size: size)
        case .snippets: SnippetsTile(size: size)
        case .logs: LogsTile(size: size)
        case .fileServer: FileServerTile(size: size)
        case .note: NoteTile(saved: widget.note ?? "") { text in var w = widget; w.note = text; update(w) }
        // The board needs two rows of height: large plays in the tile, the rest open it (Fable: wide was cut).
        case .rackFill: RackFillView(compact: size != .large)
        default: EmptyView()
        }
    }
}

/// One number, big, centred in the tile (the small tile's look, like the host counts).
struct HomeBigNumber: View {
    let value: String
    let caption: String
    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 34, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.dimText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 22)
    }
}

/// A row in a widget's list: a dot, a title, a detail on the right; clickable when given an action.
struct HomeWidgetRow: View {
    var dot: Color? = nil
    let title: String
    var detail: String = ""
    var action: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText).lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(height: HomePlan.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering && action != nil ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .accessibilityAction { action?() }
    }
}

/// The rows a tile has room for, then "+N more" (no popover: the list lives elsewhere).
private func rowsFitting<T>(_ items: [T], _ size: HomePlan.Size) -> (shown: [T], more: Int) {
    let fit = HomePlan.fit(items.count, in: size)
    return (Array(items.prefix(fit.shown)), fit.more)
}

private struct MoreLine: View {
    let more: Int
    var body: some View {
        if more > 0 {
            Text(String(localized: "+\(more) more")).font(.system(size: 11)).foregroundStyle(Theme.dimText)
                .padding(.horizontal, 6).padding(.top, 4)
        }
    }
}

// MARK: Clock

struct ClockTile: View {
    let zones: [String]
    let size: HomePlan.Size

    var body: some View {
        TimelineView(.everyMinute) { context in
            if size == .small || zones.isEmpty {
                VStack(spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: size == .small ? 30 : 40, weight: .semibold).monospacedDigit())
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11)).foregroundStyle(Theme.dimText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 22)
            } else {
                VStack(spacing: 0) {
                    zoneRow(String(localized: "Here"), TimeZone.current, context.date, bold: true)
                    ForEach(Array(zones.prefix(max(size.capacity - 1, 0)).enumerated()), id: \.offset) { _, id in
                        if let zone = TimeZone(identifier: id) { zoneRow(HomePlan.clockCity(id), zone, context.date, bold: false) }
                    }
                }
            }
        }
    }

    private func zoneRow(_ name: String, _ zone: TimeZone, _ date: Date, bold: Bool) -> some View {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return HStack {
            Text(name).font(.system(size: 12, weight: bold ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 6)
            Text(date, format: style).font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .frame(height: HomePlan.rowHeight)
    }

}

// MARK: Sessions

struct SessionsTile: View {
    let size: HomePlan.Size
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let tabs = model.tabs
        if size == .small {
            HomeBigNumber(value: "\(tabs.count)", caption: tabs.count == 1 ? String(localized: "session") : String(localized: "sessions"))
        } else if tabs.isEmpty {
            Text("No tab open").font(.system(size: 11)).foregroundStyle(Theme.dimText).padding(.horizontal, 6)
        } else {
            let fit = rowsFitting(tabs, size)
            VStack(spacing: 0) {
                ForEach(fit.shown, id: \.id) { tab in SessionRow(tab: tab) }
                MoreLine(more: fit.more)
            }
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        HomeWidgetRow(dot: SessionRow.dot(tab), title: tab.title, detail: SessionRow.state(tab)) {
            AppModel.shared.selectedID = tab.id
            DispatchQueue.main.async { AppModel.shared.focusActiveTerminal() }
        }
    }

    static func dot(_ tab: SessionTab) -> Color {
        if tab.statusInfo?.hasPrefix("disconnected") == true { return Theme.destructive }
        switch tab.content {
        case .serial(let c): return c.isTelnet ? Theme.accent : Theme.warn
        case .web: return Theme.web
        case .local, .ping: return Theme.ok
        default: return Theme.accent
        }
    }

    static func state(_ tab: SessionTab) -> String {
        if tab.statusInfo?.hasPrefix("disconnected") == true { return String(localized: "dropped") }
        switch tab.content {
        case .ssh: return "SSH"
        case .serial(let c): return c.isTelnet ? "Telnet" : String(localized: "Console")
        case .web: return "Web"
        case .files: return String(localized: "Files")
        case .ping: return "Ping"
        case .local: return String(localized: "This Mac")
        }
    }
}

// MARK: Ping

struct PingTile: View {
    let size: HomePlan.Size
    @EnvironmentObject private var model: AppModel

    private var rows: [PingTabController.Row] {
        model.tabs.flatMap { tab -> [PingTabController.Row] in
            if case .ping(let controller) = tab.content { return controller.rows }
            return []
        }
    }

    var body: some View {
        let all = rows
        if all.isEmpty {
            VStack(spacing: 6) {
                Text("No Ping tab").font(.system(size: 11)).foregroundStyle(Theme.dimText)
                Button("New Ping Tab") { model.openPing([]) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if size == .small {
            let up = all.filter { $0.stats.reach == .up }.count
            HomeBigNumber(value: "\(up)/\(all.count)", caption: String(localized: "up"))
        } else {
            let fit = rowsFitting(all, size)
            VStack(spacing: 0) {
                ForEach(fit.shown) { row in PingTileRow(row: row) }
                MoreLine(more: fit.more)
            }
        }
    }
}

private struct PingTileRow: View {
    @ObservedObject var row: PingTabController.Row

    var body: some View {
        let reach = row.stats.reach
        let latest = row.stats.samples.last ?? nil
        HomeWidgetRow(dot: reach == .up ? Theme.ok : reach == .down ? Theme.destructive : Theme.dimText,
                      title: row.name,
                      detail: latest.map { String(format: "%.0f ms", $0) } ?? (reach == .down ? String(localized: "fail") : "—"))
    }
}

// MARK: Console

struct ConsoleTile: View {
    let size: HomePlan.Size
    @EnvironmentObject private var model: AppModel
    @State private var cables: [String] = []

    var body: some View {
        Group {
            if size == .small {
                HomeBigNumber(value: "\(cables.count)", caption: String(localized: "plugged in"))
            } else if cables.isEmpty {
                Text("No console cable").font(.system(size: 11)).foregroundStyle(Theme.dimText).padding(.horizontal, 6)
            } else {
                let fit = rowsFitting(cables, size)
                VStack(spacing: 0) {
                    ForEach(fit.shown, id: \.self) { path in
                        HomeWidgetRow(dot: Theme.warn, title: SerialArrival.shortName(path), detail: String(localized: "Connect")) {
                            model.openConsole(path: path)
                        }
                    }
                    MoreLine(more: fit.more)
                }
            }
        }
        // Plugged in / pulled: read again while the tile is up (cheap — a /dev listing).
        .task {
            while !Task.isCancelled {
                let now = ConsoleTile.plugged()
                if now != cables { cables = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The USB console cables in /dev now (callout devices, `SerialArrival.isCable`).
    static func plugged() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }.filter(SerialArrival.isCable).sorted()
    }
}

// MARK: Snippets

struct SnippetsTile: View {
    let size: HomePlan.Size
    @ObservedObject private var store = AppModel.shared.snippetStore
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let snippets = store.snippets
        if size == .small {
            HomeBigNumber(value: "\(snippets.count)", caption: String(localized: "snippets"))
        } else if snippets.isEmpty {
            Text("No snippet saved").font(.system(size: 11)).foregroundStyle(Theme.dimText).padding(.horizontal, 6)
        } else {
            let fit = rowsFitting(snippets, size)
            VStack(spacing: 0) {
                ForEach(fit.shown) { snippet in
                    // Into a session: a menu of the open ones (Home has none selected).
                    Menu {
                        ForEach(model.tabs.filter { model.terminalHost(ofSession: $0.id) != nil }, id: \.id) { tab in
                            Button(tab.title) {
                                model.selectedID = tab.id
                                model.sendSnippet(snippet)
                            }
                        }
                    } label: {
                        HStack {
                            Text(snippet.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.dimText)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: HomePlan.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(model.tabs.allSatisfy { model.terminalHost(ofSession: $0.id) == nil })
                    .help(String(localized: "Type it into a session"))
                }
                MoreLine(more: fit.more)
            }
        }
    }
}

// MARK: Logs

struct LogsTile: View {
    let size: HomePlan.Size
    @EnvironmentObject private var model: AppModel
    @State private var entries: [LogLibrary.Entry] = []

    var body: some View {
        Group {
            if size == .small {
                HomeBigNumber(value: "\(entries.count)", caption: String(localized: "logs"))
            } else if entries.isEmpty {
                Text("No session log yet").font(.system(size: 11)).foregroundStyle(Theme.dimText).padding(.horizontal, 6)
            } else {
                let fit = rowsFitting(entries, size)
                VStack(spacing: 0) {
                    ForEach(fit.shown) { entry in
                        HomeWidgetRow(dot: LogLibrary.isLive(entry, now: Date()) ? Theme.ok : nil, title: entry.session,
                                      detail: entry.started.formatted(.dateTime.day().month(.abbreviated).hour().minute())) {
                            model.openLog(entry.url)
                        }
                    }
                    MoreLine(more: fit.more)
                }
            }
        }
        // Newest first; read again now and then while the tile is up.
        .task {
            while !Task.isCancelled {
                // Off the main thread: a folder of thousands of logs (Fable).
                let directory = SessionLogger.logsDirectory
                let now = await Task.detached { LogLibrary.scan(directory).sorted { $0.modified > $1.modified } }.value
                if now != entries { entries = now }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

// MARK: File Server

struct FileServerTile: View {
    let size: HomePlan.Size
    @ObservedObject private var server = FileServerModel.shared

    var body: some View {
        let active = server.transfers.filter { $0.state == .active }
        if size == .small {
            VStack(spacing: 2) {
                Circle().fill(server.running.isEmpty ? Theme.dimText : Theme.ok).frame(width: 10, height: 10)
                Text(server.running.isEmpty ? String(localized: "off") : String(localized: "on"))
                    .font(.system(size: 13, weight: .semibold))
                Text(active.isEmpty ? " " : String(localized: "\(active.count) moving"))
                    .font(.system(size: 11)).foregroundStyle(Theme.dimText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 22)
            .contentShape(Rectangle())
            .onTapGesture { server.popoverShown = true }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Which servers run; a click opens the File Server popover to change it.
                HStack(spacing: 10) {
                    ForEach(FileServerModel.Server.allCases) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(server.running[kind] != nil ? Theme.ok : Theme.dimText.opacity(0.5)).frame(width: 7, height: 7)
                            Text(kind.chipLabel).font(.system(size: 11))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: HomePlan.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { server.popoverShown = true }
                .help(String(localized: "File Server"))
                let recent = Array(server.transfers.suffix(max(size.capacity - 1, 1)).reversed())
                if recent.isEmpty {
                    Text("No transfer yet").font(.system(size: 11)).foregroundStyle(Theme.dimText).padding(.horizontal, 6)
                }
                ForEach(recent) { transfer in TransferLine(transfer: transfer) }
            }
        }
    }
}

/// One transfer: up / down, the file, the peer; a bar while it moves; ✓ or the reason when done.
private struct TransferLine: View {
    let transfer: ServerTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: transfer.isUpload ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(transfer.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                switch transfer.state {
                case .active:
                    Text(transfer.total > 0 ? "\(Int(Double(transfer.done) / Double(transfer.total) * 100))%"
                         : ByteCountFormatter.string(fromByteCount: transfer.done, countStyle: .file))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.dimText)
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
                case .failed:
                    Text(transfer.detail.isEmpty ? String(localized: "failed") : transfer.detail)
                        .font(.system(size: 11)).foregroundStyle(Theme.destructive).lineLimit(1)
                }
            }
            if transfer.state == .active, transfer.total > 0 {
                ProgressView(value: Double(transfer.done), total: Double(transfer.total))
                    .progressViewStyle(.linear).controlSize(.mini).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 6)
        .help("\(transfer.peer) · \(transfer.name)")
    }
}

// MARK: Note

/// Edited here, written back when the typing stops (1 s), the field loses
/// focus or the tile goes — not on every key (Fable: each key rewrote the
/// whole board, a synced setting).
struct NoteTile: View {
    let saved: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .onAppear { if !loaded { text = saved; loaded = true } }
            .onChange(of: saved) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, now in if !now, text != saved { commit(text) } }
            .onDisappear { if text != saved { commit(text) } }
            .task(id: text) {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled, text != saved { commit(text) }
            }
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !focused {
                    Text("A few lines of your own").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }
}
