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
    /// Writes, coalesced and off the main thread (`CommandHistorySaver`).
    private let saver: CommandHistorySaver

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    init(url: URL = CommandHistoryStore.defaultURL) {
        let loaded = CommandHistoryFile.load(from: url)
        data = loaded.data
        saver = CommandHistorySaver(url: url, suppressed: loaded.suppressWrites) { reason in
            // History is a convenience: say it once, do not interrupt typing.
            NSLog("SheepTerm: could not write history.json: %@", reason)
            Self.report(title: String(localized: "Command history not saved"),
                        String(localized: "SheepTerm could not write history.json (\(reason)). History is kept for this run only."))
        }
        if let warning = loaded.warning {
            NSLog("SheepTerm: %@", warning)
            DispatchQueue.main.async { Self.report(title: String(localized: "Command history could not be read"), warning) }
        }
        // The last couple of seconds of typing land before the process
        // ends (after applicationShouldTerminate has closed the sessions).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saver.flush() }
        }
    }

    func commands(for key: String) -> [String] { CommandHistory.commands(for: key, in: data) }

    /// A line the user entered. Silent when the filter refuses it.
    func record(_ command: String, for key: String) {
        guard CommandHistory.add(command, for: key, to: &data) else { return }
        objectWillChange.send()
        saver.changed(data)
    }

    /// An explicit change: it also re-arms saving after an unreadable file.
    func clear(_ key: String) {
        saver.rearm()
        guard CommandHistory.clear(key, in: &data) else { return }
        objectWillChange.send()
        saver.changed(data)
    }

    private static func report(title: String, _ text: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK"))
        alert.sheepStyled().runModal()
    }
}
