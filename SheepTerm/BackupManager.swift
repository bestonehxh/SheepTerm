import AppKit
import UniformTypeIdentifiers

/// One-file backup of a whole SheepTerm configuration: every group and
/// host, the recents list, credential *metadata*, and the app's settings.
///
/// **Passwords are deliberately not in it.** They live only in the macOS
/// Keychain (service `Bestchaan.SheepTerm`) and a backup file is meant to
/// be copied around — putting them in would turn every backup into a
/// plaintext password store. After restoring on another Mac, SheepTerm has
/// no password for those credentials and prompts on EVERY connection: there
/// is no path that stores a password typed at a connect prompt. Re-entering
/// the credential in Settings is what puts it in that Mac's Keychain.
@MainActor
enum BackupManager {
    static let fileExtension = "sheeptermbackup"
    /// Bump only for a change old builds could not read.
    static let currentFormat = 1

    /// The files under Application Support that make up a configuration.
    /// A missing one is normal (no credentials yet) and is simply left out
    /// of the backup.
    ///
    /// **Absence in a payload may only ever come from genuine absence on
    /// disk.** `apply` reads a name the payload does not carry as "this
    /// configuration has no such file" and DELETES the live one, so a file
    /// that is there but could not be read must abort the backup rather than
    /// be quietly skipped — see `makePayload`.
    private static let fileNames = [
        "hosts.json", "recents.json", "credentials.json",
    ]

    /// Reasons a backup or a restore is refused outright. Every case is
    /// shown to the user as-is, so each one says what went wrong AND that
    /// nothing was changed.
    enum BackupError: LocalizedError {
        /// The file exists but could not be read while making a backup.
        case unreadableFile(name: String, reason: String)
        /// A file the payload carries is not what its name says it is.
        case invalidFile(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let name, let reason):
                return """
                    \(name) is in SheepTerm's Application Support folder but could not be read \
                    (\(reason)).

                    A backup that leaves a file out means “this configuration has no such file”, \
                    so restoring one would DELETE that file. SheepTerm will not write a backup \
                    that is missing part of your configuration — nothing was written.
                    """
            case .invalidFile(let name, let reason):
                return """
                    The \(name) inside this backup is not usable: \(reason)

                    Nothing was changed.
                    """
            }
        }
    }

    /// Settings carried across — an explicit list on purpose. Copying the
    /// whole UserDefaults domain would also drag window frames and
    /// SwiftUI's own bookkeeping onto the other Mac.
    private static let settingKeys = [
        "appearanceMode", "autoReconnect", "chromeStyle", "collapsedGroups",
        "highlightDefault", "logSessions", "recentsShown", "showRecents",
        "safePasteDelayMilliseconds", "safePasteEnabled",
        "showStatusBar", "sidebarWidth", "statusShowClock", "statusShowHints",
        "statusShowIP", "statusShowSession", "terminalTheme",
        // The terminal's own look and its scrollback depth: restoring onto a
        // fresh Mac without these gives back the hosts but not the terminal
        // the user had (3.0 (26)).
        "terminalFontFamily", "terminalFontSize", "terminalFontWeight",
        "terminalFontSmoothing", "scrollbackLines",
        "TSMLanguageIndicatorEnabled",
    ]

    private static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Payload

    /// A UserDefaults value, kept typed so a Bool doesn't come back as 1.
    enum Setting: Codable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case strings([String])

        private enum CodingKeys: String, CodingKey { case type, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
            case "int": self = .int(try container.decode(Int.self, forKey: .value))
            case "double": self = .double(try container.decode(Double.self, forKey: .value))
            case "string": self = .string(try container.decode(String.self, forKey: .value))
            case "strings": self = .strings(try container.decode([String].self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                       debugDescription: "unknown setting type")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bool(let value):
                try container.encode("bool", forKey: .type); try container.encode(value, forKey: .value)
            case .int(let value):
                try container.encode("int", forKey: .type); try container.encode(value, forKey: .value)
            case .double(let value):
                try container.encode("double", forKey: .type); try container.encode(value, forKey: .value)
            case .string(let value):
                try container.encode("string", forKey: .type); try container.encode(value, forKey: .value)
            case .strings(let value):
                try container.encode("strings", forKey: .type); try container.encode(value, forKey: .value)
            }
        }

        var objectValue: Any {
            switch self {
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .strings(let value): return value
            }
        }
    }

    struct Payload: Codable {
        var format: Int
        var app: String
        var created: Date
        var device: String
        /// Raw file contents, keyed by file name (Data is base64 in JSON).
        var files: [String: Data]
        var settings: [String: Setting]
        /// Whitelist keys that had NO stored value when this payload was made,
        /// so applying it can put them back to having none.
        ///
        /// Only the pre-restore snapshot writes this, and that is the whole
        /// point: an ordinary backup means "restore what I contain", and
        /// clearing a setting it never knew about would reset something the
        /// user chose long after taking it. The snapshot means "put it back
        /// exactly as it was" — without this, restoring A, then B, then
        /// recovering A left B's settings in place wherever A had simply never
        /// stored one (A on the default `autoReconnect = true` and B on an
        /// explicit false came back as false).
        ///
        /// Optional so every payload written before it decodes unchanged.
        var absentSettings: [String]?

        var groupCount: Int {
            guard let data = files["hosts.json"],
                  let groups = try? JSONDecoder().decode([HostGroup].self, from: data) else { return 0 }
            return groups.count
        }

        var hostCount: Int {
            guard let data = files["hosts.json"],
                  let groups = try? JSONDecoder().decode([HostGroup].self, from: data) else { return 0 }
            return groups.reduce(0) { $0 + $1.hosts.count }
        }
    }

    // MARK: Making one

    /// Throws when a file that IS on disk could not be read.
    ///
    /// `try?`-and-skip made "unreadable" indistinguishable from "not there",
    /// and the two mean opposite things on restore: a name the payload does
    /// not carry makes `apply` delete the live file. So a backup taken while
    /// credentials.json was momentarily locked used to be reported as a
    /// success and then, months later, wipe the file it had failed to copy.
    /// Refusing to write a partial backup is the only way absence in a
    /// payload can keep meaning absence on disk.
    static func makePayload(recordingAbsentSettings: Bool = false) throws -> Payload {
        var files: [String: Data] = [:]
        for name in fileNames {
            let url = baseDirectory.appendingPathComponent(name)
            do {
                files[name] = try Data(contentsOf: url)
            } catch {
                // Not there at all is normal (fresh install, no saved
                // credentials): that file genuinely is not part of this
                // configuration.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                throw BackupError.unreadableFile(name: name, reason: error.localizedDescription)
            }
        }

        let settings = currentSettings()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Payload(
            format: currentFormat,
            app: "SheepTerm \(version) (\(build))",
            created: Date(),
            device: ShareCodec.deviceName,
            files: files,
            settings: settings,
            // Only for the pre-restore snapshot: see `absentSettings`.
            absentSettings: recordingAbsentSettings
                ? settingKeys.filter { settings[$0] == nil } : nil
        )
    }

    /// File → Back Up Configuration…
    static func backUp() {
        // Gather everything BEFORE asking where to put it: a configuration
        // that cannot be backed up whole is not worth a Save panel, and this
        // way no file is created for a backup that will not be written.
        let payload: Payload
        do {
            payload = try makePayload()
        } catch {
            report("Nothing was backed up", error.localizedDescription, style: .warning)
            return
        }

        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "SheepTerm-\(fileStamp("yyyy-MM-dd")).\(fileExtension)"
        panel.message = "Groups, hosts and settings. Passwords stay in your Keychain and are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            report("Could not write the backup", error.localizedDescription, style: .warning)
        }
    }

    // MARK: Restoring one

    /// File → Restore Configuration…
    static func restore() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json]
        if let type = UTType(filenameExtension: fileExtension) { types.insert(type, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SheepTerm backup to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let raw = try? decoder.decode(Payload.self, from: data) else {
            report("That file is not a SheepTerm backup",
                   "It could not be read as one. Nothing was changed.", style: .warning)
            return
        }
        // `>= 1` as well: format 0 is a number this app has never written, so a
        // file claiming it was not made here and should not be trusted to
        // decode into anything meaningful.
        guard raw.format >= 1, raw.format <= currentFormat else {
            report("This backup is from a newer SheepTerm",
                   "Update SheepTerm and try again. Nothing was changed.", style: .warning)
            return
        }
        // Checked AND cleaned before the confirmation, not after: there is no
        // point asking anyone to confirm a restore that cannot happen, and the
        // dialog should be able to say what this one will change. `payload` is
        // the cleaned copy from here on, so the counts below and the bytes
        // `apply` writes are never the file's own.
        var payload = raw
        let hygiene: ConfigurationHygiene.Report
        do {
            try validate(payload)
            // A restore and a `.sheepterm` import are the same operation —
            // someone else's file becoming your configuration — and only the
            // import was hardened. `apply` wrote the payload's bytes VERBATIM,
            // so a hosts.json carrying a 500-character name or a serial baud
            // of −1 landed on disk untouched; the baud then killed the process
            // at `cfsetspeed`. Run it here, before the confirmation, so the
            // dialog can say what a Restore will change.
            hygiene = try sanitize(&payload)
        } catch {
            report("That backup cannot be restored", error.localizedDescription, style: .warning)
            return
        }

        let stamp = DateFormatter()
        // Dates SHOWN to the user are Gregorian too, not just the ones in
        // file names: a Thai-locale Mac would otherwise date the backup
        // "18 ส.ค. 2569". Only the calendar is pinned — month names and
        // ordering still follow the machine's language.
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateStyle = .medium
        stamp.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = """
            \(payload.app) · \(payload.device) · \(stamp.string(from: payload.created))
            \(payload.groupCount) groups, \(payload.hostCount) hosts.

            This replaces every group, host and setting in SheepTerm. Your current \
            hosts, credentials list and settings are copied aside \
            first, so nothing is lost for good. Passwords are not part of a backup — \
            they stay in the Keychain of the Mac they were saved on, so a credential \
            restored from another Mac will ask for its password on every connection \
            until you re-enter it in Settings.\(hygiene.summary.map { "\n\n\($0)" } ?? "")
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Nothing is touched until every current file is safely copied aside:
        // a half-made snapshot used to be followed by a restore anyway, which
        // could leave a mix of old and new data with no way back.
        let safety: URL?
        do {
            safety = try snapshotCurrent()
        } catch {
            report("Could not set your current configuration aside",
                   "\(error.localizedDescription)\n\nNothing was changed.", style: .warning)
            return
        }
        do {
            try apply(payload)
        } catch {
            // Put back what the snapshot holds, so a failed restore leaves the
            // configuration it started from rather than a mixture.
            let rolledBack = safety.map { rollBack(from: $0) } ?? false
            report("The restore failed part-way",
                   """
                   \(error.localizedDescription)

                   \(rolledBack
                     ? "Your previous configuration was put back."
                     : "Your previous configuration is in \(safety?.lastPathComponent ?? "the pre-restore folder") inside SheepTerm's Application Support folder; restore it from there.")
                   """,
                   style: .critical)
            AppModel.shared.reloadAfterRestore()
            return
        }
        AppModel.shared.reloadAfterRestore()

        let done = NSAlert()
        done.messageText = "Configuration restored"
        let snapshotNote = safety.map {
            "Your previous configuration is in \($0.lastPathComponent) inside SheepTerm's Application Support "
                + "folder. To go back to it, use Restore and choose \(snapshotBackupName) from that folder."
        } ?? "Your previous configuration was empty, so nothing was set aside."
        // Repeated after the fact, not only before it: the confirmation is
        // gone by now and this is the sheet the user is left looking at when
        // they go hunting for the baud rate they used to have.
        done.informativeText = snapshotNote + (hygiene.summary.map { "\n\n\($0)" } ?? "")
        done.addButton(withTitle: "OK")
        if safety != nil { done.addButton(withTitle: "Show Backup Folder") }
        if done.runModal() == .alertSecondButtonReturn, let safety {
            NSWorkspace.shared.activateFileViewerSelecting([safety])
        }
    }


    /// The app's settings as the payload stores them. Shared by the backup
    /// itself and by the pre-restore snapshot, which has to capture the same
    /// thing a restore can overwrite.
    private static func currentSettings() -> [String: Setting] {
        var settings: [String: Setting] = [:]
        let defaults = UserDefaults.standard
        for key in settingKeys {
            guard let object = defaults.object(forKey: key) else { continue }
            switch object {
            // NSNumber is Bool, Int and Double all at once, so ask the
            // number itself which one it actually holds.
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    settings[key] = .bool(number.boolValue)
                } else if CFNumberIsFloatType(number) {
                    settings[key] = .double(number.doubleValue)
                } else {
                    settings[key] = .int(number.intValue)
                }
            case let text as String:
                settings[key] = .string(text)
            case let list as [String]:
                settings[key] = .strings(list)
            default:
                continue
            }
        }
        return settings
    }

    /// Copies the current configuration into a dated folder before a
    /// restore overwrites it. Returns the folder, or nil when there was
    /// nothing to copy.
    /// Throws when a file that exists could not be copied: the caller then
    /// leaves the configuration alone rather than overwriting what it failed
    /// to preserve.
    private static func snapshotCurrent() throws -> URL? {
        let folder = baseDirectory.appendingPathComponent("pre-restore-\(fileStamp("yyyyMMdd-HHmmss"))",
                                                          isDirectory: true)
        var copied = false
        for name in fileNames {
            let source = baseDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if !copied {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // Only a copy that LANDED counts. `copied = true` regardless
            // meant a second restore in the same second — same folder name,
            // every copy refused with "file exists" — still told the user
            // their previous configuration was safely in that folder.
            let destination = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            copied = true
        }
        // Settings are part of what a restore overwrites, so they are part of
        // what "copied aside first, so nothing is lost for good" has to mean.
        // This one is for `rollBack` and for reading by eye — it is a bare
        // `[String: Setting]`, which is NOT what Restore opens.
        let settings = currentSettings()
        if !settings.isEmpty {
            if !copied {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: folder.appendingPathComponent("settings.json"), options: .atomic)
            copied = true
        }
        // And a real backup beside them. The comment above this used to claim
        // the settings file could "be restored by importing this folder's file
        // like any other backup" — it could not: Restore opens a `Payload`
        // (format/app/created/device/files/settings) and this folder held raw
        // files and a bare settings dictionary. The automatic roll-back on a
        // FAILED restore worked; what had no way back was changing your mind
        // after a restore that SUCCEEDED, which is the case people actually
        // hit. Now the folder contains a file Restore accepts.
        //
        // Best effort on purpose: the raw copies above are what `rollBack`
        // uses and they have already landed. A payload that cannot be built
        // (a file unreadable at this exact moment) must not turn a good
        // snapshot into a failed restore.
        if copied, let payload = try? makePayload(recordingAbsentSettings: true) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601   // the strategy Restore decodes with
            if let data = try? encoder.encode(payload) {
                try? data.write(to: folder.appendingPathComponent(snapshotBackupName), options: .atomic)
            }
        }
        return copied ? folder : nil
    }

    /// The name of the openable backup inside a pre-restore folder.
    static let snapshotBackupName = "previous-configuration.\(fileExtension)"


    /// Checks EVERY file the payload carries before a restore writes any of
    /// them, so a bad backup fails with the live configuration untouched
    /// rather than half-replaced.
    ///
    /// hosts.json and recents.json were checked here from the start;
    /// credentials.json was not, and a corrupt one went straight over the
    /// live file. `CredentialStore` then quarantined it on the next load and
    /// came back empty — with every Keychain item orphaned, because the
    /// UUIDs that name them had just been thrown away — while the restore
    /// dialog said "Configuration restored".
    private static func validate(_ payload: Payload) throws {
        if let hosts = payload.files["hosts.json"] {
            try decodeOrThrow([HostGroup].self, from: hosts, name: "hosts.json")
        }
        if let recents = payload.files["recents.json"] {
            try decodeOrThrow([Host].self, from: recents, name: "recents.json")
        }
        if let credentials = payload.files["credentials.json"] {
            try decodeOrThrow([Credential].self, from: credentials, name: "credentials.json")
            try checkCredentialsCarryNoSecrets(credentials)
        }
    }

    /// The hygiene an import has always applied, applied to the payload's own
    /// bytes: control characters stripped from names, names capped, and a
    /// port that is not a port (or a baud that is not a baud) replaced.
    ///
    /// `validate` only ever asked whether the bytes DECODE, and `apply` then
    /// wrote them verbatim — so a restore was the way to put into hosts.json
    /// exactly what an import refuses. Sanitizing here, on the payload, means
    /// the rolled-back-on-failure, snapshot-first, validate-everything-first
    /// shape of the restore is untouched: this only changes WHAT gets written.
    ///
    /// Nothing is dropped — see `ConfigurationHygiene` — and the report is
    /// what the confirmation and the completion sheets show.
    private static func sanitize(_ payload: inout Payload) throws -> ConfigurationHygiene.Report {
        do {
            return try ConfigurationHygiene.sanitize(configurationFiles: &payload.files)
        } catch let error as ConfigurationHygiene.HygieneError {
            // Reuse the restore's own vocabulary; `HygieneError` says which
            // file and why, `invalidFile` adds "Nothing was changed."
            guard case .undecodable(let name, let reason) = error else { throw error }
            throw BackupError.invalidFile(name: name, reason: "\(reason)")
        }
    }

    private static func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws {
        do {
            _ = try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackupError.invalidFile(name: name, reason: error.localizedDescription)
        }
    }

    /// The only keys a credential entry may carry.
    ///
    /// `Credential` decodes fine with extra keys present — JSONDecoder
    /// ignores what it does not know — and `apply` writes the payload's bytes
    /// to disk VERBATIM. So a hand-made backup with a "password" field beside
    /// each credential would put plaintext secrets into Application Support,
    /// which is exactly the thing this whole file exists not to do. Checking
    /// the keys by name is what closes that; a `Codable` round-trip cannot.
    private static let credentialKeys: Set<String> = ["id", "name", "username"]

    private static func checkCredentialsCarryNoSecrets(_ data: Data) throws {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackupError.invalidFile(name: "credentials.json",
                                          reason: "it is not a list of credentials.")
        }
        for entry in entries {
            let unexpected = Set(entry.keys).subtracting(credentialKeys).sorted()
            guard unexpected.isEmpty else {
                throw BackupError.invalidFile(
                    name: "credentials.json",
                    reason: """
                        it carries fields SheepTerm never writes (\(unexpected.joined(separator: ", "))). \
                        A credential is a name and a username only — the password belongs in the \
                        Keychain, and SheepTerm will not copy one onto this Mac's disk.
                        """)
            }
        }
    }

    /// Writes the payload over the live configuration. Files that the
    /// backup does not carry are removed, so restoring a configuration with
    /// no credentials doesn't leave the old ones behind.
    /// Throws on the first file it could not write or remove, so the caller
    /// can roll back instead of reporting a success it did not achieve.
    private static func apply(_ payload: Payload) throws {
        // `restore` has already run both of these, but `apply` is what
        // overwrites the live files and it owns the promise that it never
        // writes a file it has not checked — and now, never writes one it has
        // not cleaned. Re-running is free: the hygiene pass is idempotent, so
        // a second run finds nothing and the caller's report stays the truth.
        var payload = payload
        try validate(payload)
        _ = try sanitize(&payload)
        for name in fileNames {
            let url = baseDirectory.appendingPathComponent(name)
            if let data = payload.files[name] {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let defaults = UserDefaults.standard
        let absent = Set(payload.absentSettings ?? [])
        for key in settingKeys {
            if let setting = payload.settings[key] {
                defaults.set(setting.objectValue, forKey: key)
            } else if absent.contains(key) {
                // Had no stored value when the snapshot was taken, so it must
                // have none now: removing it is what restores the DEFAULT,
                // which is what the user was on.
                defaults.removeObject(forKey: key)
            }
            // A key the payload does not carry is LEFT ALONE: restoring a
            // backup taken before a setting existed used to reset that setting
            // to its default. A backup restores what it contains — unless it
            // says otherwise (see `absentSettings`, which only the pre-restore
            // snapshot writes).
            //
            // (The pre-restore snapshot does write a settings.json — an older
            // comment here said it did not. It is still never replayed by
            // `rollBack`, and does not need to be: settings are written after
            // every file has landed, so a failure that triggers a rollback
            // happens before any of them are touched.)
        }
    }

    /// Copies a pre-restore snapshot back over the live configuration.
    /// Returns false when any file could not be put back.
    private static func rollBack(from folder: URL) -> Bool {
        var ok = true
        for name in fileNames {
            let source = folder.appendingPathComponent(name)
            let destination = baseDirectory.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: source.path) {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    // The snapshot had no such file: neither should the result.
                    try FileManager.default.removeItem(at: destination)
                }
            } catch {
                ok = false
                NSLog("SheepTerm: roll-back of %@ failed: %@", name, error.localizedDescription)
            }
        }
        return ok
    }

    /// Timestamps that end up in file names are always Gregorian and
    /// POSIX-formatted — a Thai locale would otherwise name the backup
    /// "SheepTerm-2569-08-23" and sort it nowhere near the others.
    private static func fileStamp(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }

    private static func report(_ title: String, _ detail: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
