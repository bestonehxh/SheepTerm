import AppKit
import SwiftUI
import Synchronization

/// File → Search Logs… (⌘⇧F): one query across every session log. The
/// engine is `LogSearch` (pure, harness-tested); this sheet owns the typing,
/// the background run and the list. A keystroke starts a new run after a
/// short pause and abandons the one in flight (`generation`).
struct LogSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var regex = false
    @State private var caseSensitive = false
    @State private var outcome: LogSearch.Outcome?
    @State private var problem: String?
    @State private var running = false
    @State private var selection: String?
    /// Bumped per run; a finished run whose generation is stale is dropped.
    @State private var generation = 0
    @State private var debounce: DispatchWorkItem?

    private static let queue = DispatchQueue(label: "sheepterm.logsearch", qos: .userInitiated)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Search Logs")
                    .font(.headline)
                Text("Every session log in \(LogSearchSheet.shownFolder). Double-click a line to open the log; the newest logs come first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                TextField("MAC, address, interface, error text…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search(now: true) }
                Toggle("Regex", isOn: $regex)
                Toggle("Match case", isOn: $caseSensitive)
            }

            results
                .frame(height: 360)

            HStack {
                status
                Spacer()
                Button("Reveal in Finder") { reveal() }
                    .disabled(selectedFile == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .sheepSheetChrome()
        // Esc closes it, as Esc closes any Mac sheet (Done holds Return).
        .onExitCommand { dismiss() }
        .onChange(of: text) { search(now: false) }
        .onChange(of: regex) { search(now: true) }
        .onChange(of: caseSensitive) { search(now: true) }
    }

    private static var shownFolder: String {
        LogSearchFolder.shown
    }

    // MARK: - results

    @ViewBuilder
    private var results: some View {
        if let problem {
            emptyText(problem, warn: true)
        } else if let outcome {
            if outcome.results.isEmpty {
                emptyText(text.isEmpty ? "Type to search." : "No log line matches “\(text)”.")
            } else {
                List(selection: $selection) {
                    ForEach(outcome.results) { file in
                        Section {
                            ForEach(file.hits) { hit in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(String(hit.line))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                    Text(hit.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .tag(hit.id)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(hit.file) }
                            }
                        } header: {
                            HStack {
                                Text(file.file.lastPathComponent)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text("\(file.hits.count)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            emptyText("Type to search.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if let outcome, problem == nil, !text.isEmpty {
            Text(statusText(outcome))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ o: LogSearch.Outcome) -> String {
        var parts = ["\(o.total) hit\(o.total == 1 ? "" : "s") in \(o.results.count) of \(o.filesSearched) log\(o.filesSearched == 1 ? "" : "s")"]
        if o.truncated { parts.append("stopped at \(LogSearch.maxHits) — narrow the search") }
        if o.unreadable > 0 { parts.append("\(o.unreadable) unreadable") }
        return parts.joined(separator: " · ")
    }

    private func emptyText(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(warn ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedFile: URL? {
        guard let selection, let outcome else { return nil }
        for file in outcome.results where file.hits.contains(where: { $0.id == selection }) { return file.file }
        return nil
    }

    private func reveal() {
        guard let file = selectedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: - running

    private func search(now: Bool) {
        debounce?.cancel()
        let query = LogSearch.Query(text: text, regex: regex, caseSensitive: caseSensitive)
        guard !query.text.isEmpty else {
            generation += 1
            // The run in flight polls the box, not `generation`: tell it to
            // stop, or its result would land under an empty field.
            LogSearchGeneration.shared.set(generation)
            outcome = nil
            problem = nil
            running = false
            return
        }
        let item = DispatchWorkItem { start(query) }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.3), execute: item)
    }

    private func start(_ query: LogSearch.Query) {
        generation += 1
        let mine = generation
        running = true
        problem = nil
        let files = LogSearch.files(in: LogSearchFolder.url)
        let box = LogSearchGeneration.shared
        box.set(mine)
        LogSearchSheet.queue.async {
            let result: Result<LogSearch.Outcome, Error>
            do {
                result = .success(try LogSearch.run(query, in: files, isCancelled: { box.current != mine }))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                // The box, not `generation`: this closure holds a copy of the
                // view struct, and a @State read through it is the value at
                // capture time.
                guard box.current == mine else { return }
                running = false
                switch result {
                case .success(let o):
                    outcome = o
                case .failure(let error):
                    outcome = nil
                    if case LogSearch.Failure.badRegex(let why) = error {
                        problem = "That is not a valid regular expression: \(why)"
                    } else {
                        problem = "\(error)"
                    }
                }
            }
        }
    }
}

/// Where the logs live, as the app and the sheet both see it.
enum LogSearchFolder {
    static var url: URL { SessionLogger.logsDirectory }
    static var shown: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// The generation the latest run belongs to, readable from the search queue.
/// A run polls it between chunks and stops once a newer run has started.
nonisolated final class LogSearchGeneration: Sendable {
    static let shared = LogSearchGeneration()
    private let box = Mutex(0)
    var current: Int { box.withLock { $0 } }
    func set(_ value: Int) { box.withLock { $0 = value } }
}
