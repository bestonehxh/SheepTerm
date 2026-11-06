import AppKit
import Combine
import SwiftUI

/// File ▸ Logs… (6.1): every session log in the app, by day, newest first,
/// watched live (a new log appears, one moved to the Trash in Finder goes).
/// Double-click = the log in a new read-only tab (`AppModel.openLog`);
/// right-click = open, Reveal in Finder, Copy Path, Move to Trash.
struct LogsView: View {
    static let windowID = "logs"
    @EnvironmentObject var model: AppModel
    @State private var entries: [LogLibrary.Entry] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var watcher: LogFolderWatcher?
    @State private var now = Date()

    private var directory: URL { SessionLogger.logsDirectory }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                    TextField("Search logs", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                // The sheet lives on the main window: bring it forward (Fable round 2).
                Button { model.bringMainWindowForward(); model.showLogSearch = true } label: { Image(systemName: "text.magnifyingglass") }
                    .buttonStyle(ChromeIconButtonStyle(height: 30))
                    .help("Search inside every log…")
                    .accessibilityLabel("Search inside every log…")
                Button { NSWorkspace.shared.open(directory) } label: { Image(systemName: "folder") }
                    .buttonStyle(ChromeIconButtonStyle(height: 30))
                    .help("Open the logs folder in Finder")
                    .accessibilityLabel("Open the logs folder in Finder")
            }
            .padding(14)

            let shown = LogLibrary.filter(entries, query: query)
            if shown.isEmpty {
                Spacer()
                Text(entries.isEmpty ? String(localized: "No session logs yet") : String(localized: "No match"))
                    .font(.system(size: 12)).foregroundStyle(Theme.dimText)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(LogLibrary.byDay(shown, now: now).enumerated()), id: \.offset) { _, group in
                            Section {
                                ForEach(group.entries) { row($0) }
                            } header: {
                                Text(title(of: group.day))
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dimText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                                    .background(Theme.chrome)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(Theme.chrome)
        .onAppear {
            reload()
            let watch = LogFolderWatcher(directory: directory) { reload() }
            watcher = watch
        }
        .onDisappear { watcher = nil }
        // A growing log never changes the folder's listing: sizes, the live
        // dot and Today/Yesterday refresh on a slow clock too (Fable).
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    private func reload() {
        now = Date()
        entries = LogLibrary.scan(directory)
    }

    private func title(of day: LogLibrary.Day) -> String {
        switch day {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .date(let parts):
            let date = Calendar.current.date(from: parts) ?? now
            var style = Date.FormatStyle(date: .complete, time: .omitted)
            style.calendar = Calendar(identifier: .gregorian)
            return date.formatted(style)
        }
    }

    private func row(_ entry: LogLibrary.Entry) -> some View {
        let picked = selection == entry.id
        return HStack(spacing: 10) {
            Circle().fill(LogLibrary.isLive(entry, now: now) ? Theme.ok : Color.clear).frame(width: 6, height: 6)
                .help(LogLibrary.isLive(entry, now: now) ? String(localized: "Being written") : "")
            Text(entry.session).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.started.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dimText)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(picked ? Theme.accent.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onTapGesture(count: 2) { model.openLog(entry.url) }
        .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
        .contextMenu {
            Button("Open in New Tab") { model.openLog(entry.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
            Divider()
            // The Trash, never a delete: a log is evidence.
            Button("Move to Trash") { NSWorkspace.shared.recycle([entry.url]) { _, _ in reload() } }
        }
        .help(entry.fileName)
    }
}

/// Calls `changed` on the main queue whenever the logs folder's listing
/// changes (a file added, renamed, removed). Stops when released.
final class LogFolderWatcher {
    private var source: DispatchSourceFileSystemObject?

    init(directory: URL, changed: @escaping @MainActor () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { changed() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
