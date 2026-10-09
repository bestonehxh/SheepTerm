import Foundation

/// Where the two vault files live. Named blobs, nothing more: the vault key
/// file and the sealed data file. Google Drive's appDataFolder is the real
/// one; `MemorySyncBackend` is the tests' (and a stand-in for any other
/// store an app might want later).
public protocol SyncBackend: Sendable {
    /// nil when there is no such file.
    func read(_ name: String) async throws -> Data?
    func write(_ name: String, _ data: Data) async throws
    /// Deleting a file that is not there is not an error.
    func delete(_ name: String) async throws
    /// A cheap "has it changed?": an opaque version per existing file (one
    /// small request for all of them), so a sync with nothing new anywhere
    /// downloads nothing. Missing names are absent from the answer.
    func versions(_ names: [String]) async throws -> [String: String]
}

public enum SyncBackendError: Error, Equatable, Sendable, LocalizedError {
    /// The account's sign-in is no longer valid (revoked, expired): the user
    /// has to sign in again.
    case notAuthorized
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Google sign-in is no longer valid — sign in again."
        case .http(let code, let message): return "Google Drive answered \(code): \(message)"
        case .badResponse(let what): return "Unexpected answer from Google: \(what)"
        }
    }
}

public actor MemorySyncBackend: SyncBackend {
    public private(set) var files: [String: Data] = [:]
    public private(set) var writes = 0
    public private(set) var reads = 0
    /// Like Drive: a file has an identity and a version that counts per
    /// FILE (a re-created file starts again at 1).
    private var version: [String: (file: Int, count: Int)] = [:]
    private var serial = 0
    public var failNextWrite = false

    public init() {}

    /// Tests: how long each read / write takes, so other work can run
    /// while one is "on the network".
    public var readDelay: Duration?
    public var writeDelay: Duration?
    public var deleteDelay: Duration?
    public func setDelays(read: Duration?, write: Duration?, delete: Duration? = nil) {
        readDelay = read; writeDelay = write; deleteDelay = delete
    }

    public func read(_ name: String) async throws -> Data? {
        if let readDelay { try? await Task.sleep(for: readDelay) }
        reads += 1
        return files[name]
    }

    public func write(_ name: String, _ data: Data) async throws {
        if let writeDelay { try? await Task.sleep(for: writeDelay) }
        if failNextWrite {
            failNextWrite = false
            throw SyncBackendError.http(503, "injected")
        }
        writes += 1
        files[name] = data
        bump(name)
    }

    private func bump(_ name: String) {
        if let current = version[name] {
            version[name] = (current.file, current.count + 1)
        } else {
            serial += 1
            version[name] = (serial, 1)
        }
    }

    /// Tests: every call answers "sign-in no longer valid".
    public var revoked = false
    public func setRevoked(_ value: Bool) { revoked = value }

    public func versions(_ names: [String]) async throws -> [String: String] {
        if revoked { throw SyncBackendError.notAuthorized }
        var out: [String: String] = [:]
        for name in names { if let v = version[name], files[name] != nil { out[name] = "\(v.file)/\(v.count)" } }
        return out
    }

    public func delete(_ name: String) async throws {
        if let deleteDelay { try? await Task.sleep(for: deleteDelay) }
        files[name] = nil
        version[name] = nil
    }

    public func setFailNextWrite() { failNextWrite = true }
    public func overwrite(_ name: String, _ data: Data?) {
        files[name] = data
        if data == nil { version[name] = nil } else { bump(name) }
    }
}
