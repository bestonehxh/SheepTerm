import AppKit
import Combine
import Foundation

/// snippets.json — the saved commands behind the Snippets menu. Same rules
/// as credentials.json: an unreadable file is preserved as `.corrupt-<stamp>`
/// and writes stop until the user changes something; every write leaves a
/// `.bak`; the file is part of Back Up Configuration.
@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet]

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("snippets.json")
    }

    private var suppressWritesAfterCorruptLoad = false

    init() {
        let (loaded, warning) = Self.load()
        snippets = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        if let warning { DispatchQueue.main.async { Self.reportCorruptLoad(warning) } }
    }

    /// Re-reads snippets.json after a backup restore.
    func reloadFromDisk() {
        let (loaded, warning) = Self.load()
        snippets = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        if let warning { DispatchQueue.main.async { Self.reportCorruptLoad(warning) } }
    }

    private static func load() -> (value: [Snippet], warning: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) { return ([], nil) }
            let warning = "\(fileURL.lastPathComponent) could not be read (\(error.localizedDescription)). "
                + "The snippet list starts empty and the file will not be overwritten until you change something."
            NSLog("SheepTerm: %@", warning)
            return ([], warning)
        }
        do {
            return (try SnippetCodec.decode(data), nil)
        } catch {
            let corruptURL = fileURL.appendingPathExtension("corrupt-\(corruptStamp())")
            do {
                try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            } catch {
                NSLog("SheepTerm: could not move corrupt snippets.json aside: %@", error.localizedDescription)
            }
            let warning = "snippets.json was unreadable; the original was preserved as \(corruptURL.lastPathComponent) and the snippet list starts empty."
            NSLog("SheepTerm: %@ (decode error: %@)", warning, error.localizedDescription)
            return ([], warning)
        }
    }

    private static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - mutations (every one re-arms saving)

    @discardableResult
    func add(name: String, text: String, sendReturn: Bool = true) -> Snippet {
        let snippet = SnippetCodec.normalised(Snippet(name: name, text: text, sendReturn: sendReturn))
        suppressWritesAfterCorruptLoad = false
        snippets.append(snippet)
        save()
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        suppressWritesAfterCorruptLoad = false
        snippets[index] = SnippetCodec.normalised(snippet)
        save()
    }

    func remove(_ snippet: Snippet) {
        suppressWritesAfterCorruptLoad = false
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    /// Move one step up (`-1`) or down (`+1`) in the menu order.
    func move(_ snippet: Snippet, by delta: Int) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let target = index + delta
        guard target >= 0, target < snippets.count else { return }
        suppressWritesAfterCorruptLoad = false
        snippets.swapAt(index, target)
        save()
    }

    @discardableResult
    func save() -> Bool {
        guard !suppressWritesAfterCorruptLoad else {
            NSLog("SheepTerm: write to snippets.json suppressed until the first user change (corrupt previous file was preserved)")
            return false
        }
        do {
            let data = try SnippetCodec.encode(snippets)
            if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                let backupURL = Self.fileURL.appendingPathExtension("bak")
                let stagingURL = Self.fileURL.appendingPathExtension("bak.tmp")
                do {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.copyItem(at: Self.fileURL, to: stagingURL)
                    _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: stagingURL)
                } catch {
                    try? FileManager.default.removeItem(at: stagingURL)
                    NSLog("SheepTerm: could not back up snippets.json (%@) — not overwriting it", error.localizedDescription)
                    throw error
                }
            }
            try data.write(to: Self.fileURL, options: .atomic)
            return true
        } catch {
            Self.reportSaveFailure(error)
            return false
        }
    }

    private static func reportCorruptLoad(_ warning: String) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saved snippets could not be read"
        alert.informativeText = warning
        alert.addButton(withTitle: "OK")
        alert.sheepStyled().runModal()
    }

    private static func reportSaveFailure(_ error: Error) {
        let alert = SheepAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snippets not saved"
        alert.informativeText = "SheepTerm could not write snippets.json (\(error.localizedDescription)). The change you just made is not saved."
        alert.addButton(withTitle: "OK")
        alert.sheepStyled().runModal()
    }
}
