import Foundation

// The shared contract between the Files tab (client UI) and every file
// protocol engine — SFTP, SCP, FTP, TFTP — and between the File Server
// popover and every server engine. Pure value types + protocols, no AppKit.

/// One row of a remote directory listing.
nonisolated struct RemoteEntry: Sendable, Hashable, Identifiable {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool = false
    var size: Int64?
    var modified: Date?
    /// "rwxr-xr-x"-style when the protocol reports it.
    var permissions: String?
    var id: String { name }
}

/// Bytes moved so far, and the total when known.
typealias TransferProgress = @Sendable (_ done: Int64, _ total: Int64?) -> Void

nonisolated enum RemoteFileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server's host key is not in SheepTerm's known_hosts (or changed).
    /// `fingerprint` = "SHA256:…"; the UI asks, then reconnects with the
    /// matching `HostKeyDecision`.
    case hostKeyUnknown(fingerprint: String, keyType: String)
    case hostKeyChanged(fingerprint: String, keyType: String)
    case authenticationFailed
    /// A password is needed and none was given.
    case passwordRequired
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    /// The protocol cannot do this (e.g. listing over TFTP, browsing a
    /// device that refuses the SFTP subsystem).
    case unsupported(String)
    case cancelled
    case connection(String)
    case remote(String)

    var description: String {
        switch self {
        case .hostKeyUnknown(let fp, let type): return "Unknown host key (\(type) \(fp))"
        case .hostKeyChanged(let fp, let type): return "HOST KEY CHANGED (\(type) \(fp))"
        case .authenticationFailed: return "Authentication failed"
        case .passwordRequired: return "Password required"
        case .notFound(let p): return "Not found: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .unsupported(let what): return what
        case .cancelled: return "Cancelled"
        case .connection(let why): return why
        case .remote(let why): return why
        }
    }
}

/// How much one download may write: the free space of the destination
/// volume less a 1 GB reserve (a hostile or broken server that never sends
/// EOF must not fill the Mac's disk), and never more than 64 GB.
nonisolated enum DownloadCap {
    static let ceiling: Int64 = 64 * 1024 * 1024 * 1024
    static let reserve: Int64 = 1024 * 1024 * 1024
    #if SHEEPTERM_TESTING
    /// The harness's "disk": a hostile server must be stopped at this.
    nonisolated(unsafe) static var testOverride: Int64?
    #endif

    static func bytes(for local: URL) -> Int64 {
        #if SHEEPTERM_TESTING
        if let testOverride { return testOverride }
        #endif
        var fs = statfs()
        guard statfs(local.deletingLastPathComponent().path, &fs) == 0 else { return ceiling }
        let free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        return max(0, min(ceiling, free - reserve))
    }
}

/// What to do with a host key that is not (yet) trusted — the answer to
/// `RemoteFileError.hostKeyUnknown`.
nonisolated enum HostKeyDecision: Sendable, Equatable {
    /// Only keys already in known_hosts are accepted.
    case requireKnown
    /// Accept this exact fingerprint for this connection, write nothing.
    case trustOnce(fingerprint: String)
    /// Accept it and add it to SheepTerm's known_hosts.
    case trustAndSave(fingerprint: String)
}

/// Where and how to connect. One value for every protocol; fields a
/// protocol does not use are ignored.
nonisolated struct RemoteEndpoint: Sendable, Equatable {
    enum Proto: String, Sendable, CaseIterable { case sftp, scp, ftp, tftp }
    var proto: Proto
    var host: String
    var port: Int
    var username: String = ""
    var password: String?
    /// OpenSSH private key text (SFTP/SCP), when the host uses a key.
    var privateKey: String?
    var keyPassphrase: String?
    /// Allow the legacy algorithm set (old switches), like an SSH host's
    /// cipher mode.
    var legacyAlgorithms: Bool = false
    var hostKey: HostKeyDecision = .requireKnown

    static func defaultPort(_ proto: Proto) -> Int {
        switch proto {
        case .sftp, .scp: return 22
        case .ftp: return 21
        case .tftp: return 69
        }
    }
}

/// A connected client. Every call is async and honours Task cancellation
/// (a cancelled transfer throws `.cancelled` and leaves no partial file at
/// the destination: write to a temp name, rename at the end).
nonisolated protocol RemoteFileClient: AnyObject, Sendable {
    /// False for TFTP and for SCP on a device without the SFTP subsystem:
    /// the tab then shows a get/put form instead of a browser.
    var canBrowse: Bool { get }
    /// The directory the session starts in ("/" when unknown).
    func home() async throws -> String
    func list(_ path: String) async throws -> [RemoteEntry]
    func download(_ remotePath: String, to local: URL, progress: @escaping TransferProgress) async throws
    func upload(_ local: URL, to remotePath: String, progress: @escaping TransferProgress) async throws
    func makeDirectory(_ path: String) async throws
    func remove(_ path: String, isDirectory: Bool) async throws
    func rename(_ from: String, to: String) async throws
    func close()
}

/// One device transfer as the File Server popover shows it (every server
/// engine reports these). `total == 0` =
/// size unknown. `isUpload` is from the device's side: true = the device is
/// pushing a file TO this Mac (a config backup).
nonisolated struct ServerTransfer: Identifiable, Equatable, Sendable {
    enum State: Sendable { case active, done, failed }
    /// Per-session token: a device retrying the same file must not have the
    /// dead attempt's `.failed` land on the retry's bar.
    let token: String
    let peer: String
    let name: String
    let isUpload: Bool
    var done: Int64
    var total: Int64
    var state: State = .active
    var detail: String = ""
    /// Which server reported it (`FileServerModel.Server` raw value); set
    /// by the model, engines leave it empty.
    var server: String = ""
    var id: String { token }
}

/// A server a device connects to (File Server popover). Every engine reads
/// names through these closures — `FileServerPlan.readTarget` /
/// `writeTarget` — so what a device may touch is decided in ONE place.
nonisolated struct FileServerAccess: Sendable {
    /// Name the device asked for → the file to send, or nil (refuse).
    var readURL: @Sendable (String) -> URL?
    /// Name the device wants to write → where it lands, or nil (refuse:
    /// writes off, bad name, or the name is taken).
    var writeURL: @Sendable (String) -> URL?
    /// What a directory listing shows (the one served file, or nothing).
    var listing: @Sendable () -> [URL]
    /// Login for SFTP/SCP/FTP. Compared in constant time.
    var username: String
    var password: String
    /// Every transfer start/progress/end, for the popover's bars.
    var onProgress: @Sendable (ServerTransfer) -> Void
}

/// One finished transfer in the Transfer Log (File Server or a Files tab).
/// `toMac`: the bytes came to this Mac (a device uploaded / we downloaded).
/// Never holds a password or a path outside the file's name.
nonisolated struct TransferLogEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var proto: String           // "TFTP", "SFTP/SCP", "FTP", "SFTP", "SCP"
    var device: String          // the device's address
    var name: String
    var toMac: Bool
    var bytes: Int64
    var ok: Bool
    var reason: String = ""
}

/// The log file is JSON lines (append-only; a torn last line from a crash
/// is skipped, not fatal), trimmed to `keep` entries when it grows past
/// `keep * 2`. Pure parts here so the harness can pin them.
nonisolated enum TransferLogFile {
    static let keep = 1000
    static let fieldLimit = 255

    /// What a peer sent (a file name, an error text) as the log keeps it:
    /// printable, one line, at most `fieldLimit` characters — the wire may
    /// hand over 64 KB of anything (security review, 6.0).
    static func clean(_ text: String) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.map {
            ($0.value < 0x20 || $0.value == 0x7F || (0x80..<0xA0).contains($0.value)) ? " " : $0
        }))
        return printable.count > fieldLimit ? String(printable.prefix(fieldLimit - 1)) + "…" : printable
    }

    static func sanitized(_ e: TransferLogEntry) -> TransferLogEntry {
        var e = e
        e.name = clean(e.name); e.reason = clean(e.reason); e.device = clean(e.device); e.proto = clean(e.proto)
        return e
    }

    static func line(_ entry: TransferLogEntry) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Newest first; unreadable lines are skipped.
    static func parse(_ data: Data) -> [TransferLogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(TransferLogEntry.self, from: Data($0)) }.reversed()
    }

    /// The file rewritten with the newest `keep` entries (oldest first).
    static func trimmed(_ entries: [TransferLogEntry]) -> Data {
        var out = Data()
        for entry in entries.prefix(keep).reversed() { if let l = line(entry) { out.append(l) } }
        return out
    }
}
