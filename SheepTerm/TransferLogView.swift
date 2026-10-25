import AppKit
import Combine
import SwiftUI

/// Every finished transfer — File Server and Files tabs — kept in
/// Application Support/SheepTerm/transfer-log.jsonl (newest 1000).
@MainActor
final class TransferLog: ObservableObject {
    static let shared = TransferLog()
    @Published private(set) var entries: [TransferLogEntry] = []

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("transfer-log.jsonl")
    }

    private var loaded = false
    /// Entries that arrived before the file was read: written after it.
    private var early: [TransferLogEntry] = []

    /// Read off main (a big file must not stall launch); anything added
    /// meanwhile goes on top and into the file once the read is done.
    private init() {
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            let read = (try? Data(contentsOf: url)).map(TransferLogFile.parse) ?? []
            await MainActor.run { TransferLog.shared.finishLoading(read) }
        }
    }

    private func finishLoading(_ read: [TransferLogEntry]) {
        guard !loaded else { return }       // cleared meanwhile
        loaded = true
        entries = early + read
        let pending = early
        early = []
        for entry in pending.reversed() { append(entry) }
    }

    func add(_ raw: TransferLogEntry) {
        let entry = TransferLogFile.sanitized(raw)
        entries.insert(entry, at: 0)
        guard loaded else { early.insert(entry, at: 0); return }
        append(entry)
    }

    private func append(_ entry: TransferLogEntry) {
        guard let line = TransferLogFile.line(entry) else { return }
        let url = Self.fileURL
        if entries.count > TransferLogFile.keep * 2 {
            entries = Array(entries.prefix(TransferLogFile.keep))
            try? TransferLogFile.trimmed(entries).write(to: url, options: .atomic)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    func clear() {
        loaded = true
        early = []
        entries = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}

/// File ▸ Transfer Log… / the File Server popover's clock button.
struct TransferLogView: View {
    @ObservedObject private var log = TransferLog.shared
    @Environment(\.dismiss) private var dismiss

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transfer Log").font(.headline)
            if log.entries.isEmpty {
                Text("No transfers yet")
                    .foregroundStyle(Theme.dimText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(log.entries) {
                    TableColumn("Time") { Text(Self.time.string(from: $0.date)).monospacedDigit() }
                        .width(132)
                    TableColumn("Device") { Text($0.device) }
                        .width(min: 90, ideal: 104, max: 130)
                    TableColumn("File") { e in
                        HStack(spacing: 4) {
                            Image(systemName: e.toMac ? "arrow.down" : "arrow.up")
                                .foregroundStyle(Theme.dimText)
                                .help(e.toMac ? String(localized: "To this Mac") : String(localized: "From this Mac"))
                            Text(e.name).lineLimit(1).truncationMode(.middle).help(e.name)
                        }
                    }
                    .width(min: 120)
                    TableColumn("Protocol") { Text($0.proto) }
                        .width(58)
                    TableColumn("Size") { e in
                        Text(e.bytes > 0 ? ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file) : "—").monospacedDigit()
                    }
                    .width(72)
                    TableColumn("Result") { e in
                        HStack(spacing: 4) {
                            Text(e.ok ? "Success" : "Failed").foregroundStyle(e.ok ? Theme.ok : Theme.destructive)
                            if !e.ok {
                                Image(systemName: "info.circle").foregroundStyle(Theme.dimText)
                                    .help(e.reason.isEmpty ? String(localized: "failed") : e.reason)
                            }
                        }
                    }
                    .width(84)
                }
                .font(.system(size: 12))
            }
            HStack {
                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear the log")
                .disabled(log.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 440)
        .sheepSheetChrome()
    }
}
