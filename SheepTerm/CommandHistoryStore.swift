import AppKit
import Combine
import Foundation

/// history.json — the command lines typed in each session, per host. Not part
/// of Back Up Configuration and not in a `.sheepterm` export on purpose: it
/// is a record of what was typed on a device, which is nobody else's.
/// Rules: `CommandHistory` / `CommandHistoryFile` (pure, harness-tested).
@MainActor
final class CommandHistoryStore: ObservableObject {
    private(set) var data = CommandHistoryData()
    private var suppressWrites = false
    private var backedUpThisRun = false
    private let url: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    init(url: URL = CommandHistoryStore.defaultURL) {
        self.url = url
        let loaded = CommandHistoryFile.load(from: url)
        data = loaded.data
        suppressWrites = loaded.suppressWrites
        if let warning = loaded.warning {
            NSLog("SheepTerm: %@", warning)
            DispatchQueue.main.async { Self.report(title: "Command history could not be read", warning) }
        }
    }

    func commands(for key: String) -> [String] { CommandHistory.commands(for: key, in: data) }

    /// A line the user entered. Silent when the filter refuses it.
    func record(_ command: String, for key: String) {
        guard CommandHistory.add(command, for: key, to: &data) else { return }
        objectWillChange.send()
        save()
    }

    /// An explicit change: it also re-arms saving after an unreadable file.
    func clear(_ key: String) {
        suppressWrites = false
        guard CommandHistory.clear(key, in: &data) else { return }
        objectWillChange.send()
        save()
    }

    private func save() {
        guard !suppressWrites else { return }
        do {
            try CommandHistoryFile.save(data, to: url, backup: !backedUpThisRun)
            backedUpThisRun = true
        } catch {
            // History is a convenience: say it once, do not interrupt typing.
            NSLog("SheepTerm: could not write history.json: %@", error.localizedDescription)
            suppressWrites = true
            Self.report(title: "Command history not saved",
                        "SheepTerm could not write history.json (\(error.localizedDescription)). History is kept for this run only.")
        }
    }

    private static func report(title: String, _ text: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.sheepStyled().runModal()
    }
}
